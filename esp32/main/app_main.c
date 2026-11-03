#include <stdbool.h>
#include <stdint.h>

#include "esp_err.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "esp_timer.h"
#include "sdkconfig.h"

#include "control_event.h"
#include "midi_bridge.h"
#include "phone_uart.h"
#include "phone_command.h"
#include "pedal_refresh.h"
#include "protocol_vectors.h"
#include "score_store.h"
#include "uart_link.h"
#include "usb_midi_host.h"
#include "practice_protocol.h"
#include "driver/uart.h"

static const char *TAG = "midi_bridge";
/*
 * SMK-25 mirrors its stream on USB-MIDI cable numbers 0 and 1. Accept cable
 * 0 once; the 88-key controller is directly connected to the FPGA USB0.
 */
#define SMK25_ACCEPTED_USB_MIDI_CABLE 0U
#define MIDI_SOURCE_COUNT 1U

static smk25_midi_bridge_t s_bridges[MIDI_SOURCE_COUNT];
static StaticQueue_t s_queue_storage;
static uint8_t s_queue_bytes[CONFIG_SMK25_EVENT_QUEUE_DEPTH * sizeof(smk25_control_event_t)];
static QueueHandle_t s_event_queue;
static portMUX_TYPE s_fault_lock = portMUX_INITIALIZER_UNLOCKED;
static portMUX_TYPE s_bridge_lock = portMUX_INITIALIZER_UNLOCKED;
static volatile bool s_panic_pending;
static volatile uint32_t s_queue_overflow_count;
static volatile bool s_score_playing;
static volatile bool s_score_task_active;
static TaskHandle_t s_score_task;
static volatile bool s_practice_requested;
static volatile bool s_practice_done;
static volatile bool s_practice_ack;
static volatile uint8_t s_practice_session;
static practice_plan_t s_practice_plan;
static volatile int64_t s_practice_origin;
static void practice_run(void);
static int64_t practice_origin_get(void)
{
    portENTER_CRITICAL(&s_fault_lock);int64_t t=s_practice_origin;portEXIT_CRITICAL(&s_fault_lock);return t;
}
static void score_reset_view(void);

static void request_panic(void)
{
    portENTER_CRITICAL(&s_fault_lock);
    s_panic_pending = true;
    portEXIT_CRITICAL(&s_fault_lock);
}

static bool take_panic(void)
{
    bool pending;
    portENTER_CRITICAL(&s_fault_lock);
    pending = s_panic_pending;
    s_panic_pending = false;
    portEXIT_CRITICAL(&s_fault_lock);
    return pending;
}

static void usb_packet_callback(uint8_t source, const uint8_t packet[4], void *context)
{
    (void)context;
    if (source >= MIDI_SOURCE_COUNT) {
        return;
    }
    const uint8_t cable = (packet[0] >> 4) & 0x0FU;
    if (cable != SMK25_ACCEPTED_USB_MIDI_CABLE) {
        ESP_LOGD(TAG, "ignoring mirrored USB-MIDI cable %u packet", cable);
        return;
    }
    smk25_control_event_t event;
    portENTER_CRITICAL(&s_bridge_lock);
    const bool decoded = smk25_midi_bridge_usb_packet(&s_bridges[source], packet, &event);
    portEXIT_CRITICAL(&s_bridge_lock);
    if (!decoded) {
        return;
    }
    ESP_LOGD(TAG,
             "source %u USB-MIDI %02x %02x %02x %02x -> event %02x %02x %02x %02x %02x %02x %02x %02x",
             source, packet[0], packet[1], packet[2], packet[3],
             event.bytes[0], event.bytes[1], event.bytes[2], event.bytes[3],
             event.bytes[4], event.bytes[5], event.bytes[6], event.bytes[7]);
    if ((event.bytes[0] & 0x3fU) == SMK25_EV_SUSTAIN)
        ESP_LOGI(TAG, "SMK25 pedal ch=%u value=%u queue=%u", event.bytes[1] & 0x0fU,
                 (unsigned)((((uint16_t)event.bytes[4] << 8) | event.bytes[5]) >> 9),
                 (unsigned)uxQueueMessagesWaiting(s_event_queue));
    if (xQueueSend(s_event_queue, &event, 0) != pdTRUE) {
        ++s_queue_overflow_count;
        ESP_LOGE(TAG, "USB MIDI queue overflow, count=%lu; requesting safe panic",
                 (unsigned long)s_queue_overflow_count);
        request_panic();
    }
}

static bool phone_command_callback(const uint8_t bytes[8], void *context)
{
    (void)context;
    if (bytes[0] == SCORE_RECORD_TYPE)
        return !s_score_task_active && score_store_append(bytes);
    if (bytes[0] == SCORE_CONTROL_TYPE) {
        if (bytes[6] != 0U || bytes[7] != 0U) return false;
        const uint16_t parameter = ((uint16_t)bytes[2] << 8) | bytes[3];
        const uint16_t crc = ((uint16_t)bytes[4] << 8) | bytes[5];
        switch (bytes[1]) {
        case 0: return !s_score_task_active && score_store_begin(parameter);
        case 1: {
            const bool committed = !s_score_task_active && score_store_commit(crc);
            const uint8_t response[8] = {0x52, 1, committed ? 1 : 0, 0, bytes[4], bytes[5], 0, 0};
            music_phone_uart_publish_raw(response, sizeof(response));
            if (committed) score_reset_view();
            return committed;
        }
        case 2:
            if (s_score_task_active || score_store_count() == 0U) return false;
            s_score_task_active = true;
            s_practice_requested = false;
            s_score_playing = true;
            xTaskNotifyGive(s_score_task);
            return true;
        case 3: {
            s_score_playing=false;
            smk25_control_event_t stop;
            smk25_control_event_pack(&stop,14,SMK25_SRC_SCORE,0,0,0,3,0,0,0);
            return xQueueSend(s_event_queue,&stop,0)==pdTRUE;
        }
        case 4:
            if(s_score_task_active||score_store_count()==0U)return false;
            s_practice_session=(uint8_t)parameter;
            s_practice_requested=true;s_practice_done=false;s_practice_ack=false;
            s_score_task_active=true;s_score_playing=true;
            xTaskNotifyGive(s_score_task);return true;
        default: return false;
        }
    }
    smk25_control_event_t event;
    music_phone_keymap_t map;
    const music_phone_command_kind_t kind = music_phone_command_decode(bytes, &event, &map);
    if (kind == MUSIC_PHONE_KEYMAP) {
        portENTER_CRITICAL(&s_bridge_lock);
        const bool accepted = smk25_midi_bridge_set_note_map(&s_bridges[map.source],
                                                              map.input_note, map.output_note);
        portEXIT_CRITICAL(&s_bridge_lock);
        ESP_LOGI(TAG, "phone map source=%u note=%u -> %u", map.source,
                 map.input_note, map.output_note);
        return accepted;
    }
    if (kind != MUSIC_PHONE_EVENT) {
        return false;
    }
    if (xQueueSend(s_event_queue, &event, 0) != pdTRUE) {
        ++s_queue_overflow_count;
        request_panic();
        return false;
    }
    return true;
}

static void score_queue_note(uint8_t instrument, uint8_t note,
                             uint8_t velocity, bool on)
{
    smk25_control_event_t event;
    smk25_control_event_pack(&event, on ? SMK25_EV_NOTE_ON : SMK25_EV_NOTE_OFF,
                             SMK25_SRC_SCORE, 11U + instrument, instrument, 0, note,
                             on ? smk25_scale7(velocity) : 0, 0, 0);
    if (xQueueSend(s_event_queue, &event, pdMS_TO_TICKS(100)) != pdTRUE) {
        ESP_LOGE(TAG, "score event queue stalled; stopping local playback");
        s_score_playing = false;
        request_panic();
    }
}

/* C-major numbered notation: octave[7:4], accidental[3], degree[2:0].
 * The preview conveys pitch only; its timing remains in the Flash score. */
static uint8_t score_pitch_code(uint8_t note)
{
    static const uint8_t degree[12] = {1, 1, 2, 2, 3, 4, 4, 5, 5, 6, 6, 7};
    static const uint8_t sharp[12] = {0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0};
    const uint8_t pitch_class = note % 12U;
    const uint8_t octave = note / 12U > 0U ? note / 12U - 1U : 0U;
    return (uint8_t)((octave << 4) | (sharp[pitch_class] << 3) |
                     degree[pitch_class]);
}

static void score_queue_view(uint8_t operation, uint8_t slot,
                             const score_note_event_t *note, uint8_t meta)
{
    smk25_control_event_t event;
    smk25_control_event_pack(&event, SMK25_EV_SCORE_VIEW, SMK25_SRC_SCORE, 0,
                             note != NULL ? note->instrument : 0, 0,
                             note != NULL ? score_pitch_code(note->note) : 0,
                             (uint16_t)((uint16_t)(meta & 0x0fU) << 8 | slot),
                             operation, 0);
    if (xQueueSend(s_event_queue, &event, pdMS_TO_TICKS(100)) != pdTRUE) {
        ESP_LOGE(TAG, "score preview queue stalled; stopping local playback");
        s_score_playing = false;
        request_panic();
    }
}

static void score_queue_next_view(uint16_t count, uint16_t *scan, uint8_t slot)
{
    score_note_event_t event;
    while (*scan < count) {
        const uint16_t index = (*scan)++;
        if (score_store_get(index, &event) && event.on) {
            score_queue_view(1U, slot, &event,
                             score_store_note_meta(index));
            return;
        }
    }
}

static void score_reset_view(void)
{
    const uint16_t count = score_store_count();
    uint16_t scan = 0;
    score_queue_view(0U, 0U, NULL, 0U);
    for (uint8_t slot = 0; slot < 16U; ++slot)
        score_queue_next_view(count, &scan, slot);
}

static void score_queue_led(uint8_t operation, const score_note_event_t *note)
{
    smk25_control_event_t event;
    smk25_control_event_pack(&event, SMK25_EV_SCORE_LED, SMK25_SRC_SCORE, 0,
                             note != NULL ? note->instrument : 0, 0,
                             note != NULL ? note->note : 0, 0, operation, 0);
    if (xQueueSend(s_event_queue, &event, pdMS_TO_TICKS(100)) != pdTRUE) {
        ESP_LOGE(TAG, "score LED queue stalled; stopping local playback");
        s_score_playing = false;
        request_panic();
    }
}

static bool score_find_next_on(uint16_t count, uint16_t *scan,
                                score_note_event_t *event)
{
    while (*scan < count) {
        if (score_store_get((*scan)++, event) && event->on) return true;
    }
    return false;
}

static void score_wait_until(int64_t origin, uint32_t at_ms)
{
    while (s_score_playing && !(s_practice_requested && s_practice_done)) {
        const int64_t remaining = origin + (int64_t)at_ms * 1000 -
                                  esp_timer_get_time();
        if (remaining <= 0) break;
        if (remaining > 2000) {
            const int64_t wait_ms=remaining/1000-1;
            vTaskDelay(pdMS_TO_TICKS(wait_ms>10?10:wait_ms));
        }
        else taskYIELD();
    }
}

static void score_playback_task(void *arg)
{
    (void)arg;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        s_score_task_active = true;
        if(s_practice_requested){
            practice_run();s_practice_requested=false;s_score_playing=false;s_score_task_active=false;continue;
        }
        bool held[3][128] = {{false}};
        const uint16_t count = score_store_count();
        uint16_t view_scan = 0;
        uint16_t guide_scan = 0;
        uint16_t play_index = 0;
        bool have_guide = false;
        score_note_event_t guide_event;
        score_queue_led(0U, NULL); /* remove guidance from an earlier song */
        score_queue_view(0U, 0U, NULL, 0U); /* clear stale score from earlier play */
        for (uint8_t slot = 0; slot < 16U && s_score_playing; ++slot)
            score_queue_next_view(count, &view_scan, slot);
        const int64_t origin = esp_timer_get_time();
        ESP_LOGI(TAG, "playing %u locally stored score events", count);
        while (s_score_playing && play_index < count) {
            score_note_event_t score_event;
            if (!score_store_get(play_index, &score_event)) break;
            if (!have_guide)
                have_guide = score_find_next_on(count, &guide_scan, &guide_event);
            const uint32_t guide_at = have_guide && guide_event.at_ms > 200U ?
                                      guide_event.at_ms - 200U : 0U;
            if (have_guide && guide_at <= score_event.at_ms) {
                score_wait_until(origin, guide_at);
                if (!s_score_playing) break;
                score_queue_led(1U, &guide_event); /* blue, 200 ms early */
                have_guide = false;
                continue;
            }
            score_wait_until(origin, score_event.at_ms);
            if (!s_score_playing) break;
            ++play_index;
            score_queue_note(score_event.instrument, score_event.note,
                             score_event.velocity, score_event.on);
            held[score_event.instrument][score_event.note] = score_event.on;
            if (score_event.on) {
                score_queue_led(2U, &score_event); /* white: now expected */
                score_queue_view(2U, 0U, NULL, 0U); /* next pitch becomes current */
                score_queue_next_view(count, &view_scan, 15U);
            } else {
                score_queue_led(3U, &score_event); /* clear after Note Off */
            }
        }
        /* Release this source only. A global panic would interrupt the live keyboards. */
        for (unsigned instrument = 0; instrument < 3; ++instrument)
            for (unsigned note = 0; note < 128; ++note)
                if (held[instrument][note])
                    score_queue_note(instrument, note, 0, false);
        score_queue_led(0U, NULL);
        score_reset_view();
        s_score_playing = false;
        s_score_task_active = false;
        ESP_LOGI(TAG, "local score playback finished");
    }
}

static void usb_disconnect_callback(uint8_t source, void *context)
{
    (void)context;
    ESP_LOGW(TAG, "USB-MIDI source %u disconnected; sending safe all-notes-off", source);
    request_panic();
}

static bool practice_queue(uint8_t type,uint8_t id,uint32_t value)
{
    smk25_control_event_t event;
    smk25_control_event_pack(&event,type,SMK25_SRC_SCORE,0,0,0,id,(uint16_t)value,(uint8_t)(value>>16),0);
    if(xQueueSend(s_event_queue,&event,pdMS_TO_TICKS(100))==pdTRUE)return true;
    s_score_playing=false;request_panic();return false;
}

static void practice_view_target(uint16_t index,uint8_t slot)
{
    if(index>=s_practice_plan.count)return;
    const practice_target_t *target=&s_practice_plan.targets[index];
    score_note_event_t note;
    if(score_store_get(target->record_index,&note))
        score_queue_view(1U,slot,&note,score_store_note_meta(target->record_index));
}

static void practice_run(void)
{
    practice_plan_begin(&s_practice_plan);
    int error=PRACTICE_OK;
    for(uint16_t i=0;i<score_store_count();++i){
        score_note_event_t event;
        if(!score_store_get(i,&event)){error=PRACTICE_BAD_TIME;break;}
        error=practice_plan_add(&s_practice_plan,event.at_ms,event.note,event.instrument,event.on,i);
        if(error!=PRACTICE_OK)break;
    }
    if(error==PRACTICE_OK&&s_practice_plan.count==0)error=PRACTICE_EMPTY;
    if(error!=PRACTICE_OK){
        ESP_LOGE(TAG,"practice rejected before start, reason=%d",error);
        practice_feedback_t f={.session=s_practice_session,.flags=0x84,.last_result=(uint8_t)(0x80+error)};
        uint8_t packet[20];practice_feedback_ble(&f,0,packet);music_phone_uart_publish_raw(packet,sizeof(packet));
        return;
    }
    score_queue_led(0,NULL);score_queue_view(0,0,NULL,0);
    for(uint16_t i=0;i<16U&&i<s_practice_plan.count;++i)practice_view_target(i,(uint8_t)i);
    portENTER_CRITICAL(&s_fault_lock);s_practice_origin=0;portEXIT_CRITICAL(&s_fault_lock);
    const uint32_t final_at=s_practice_plan.targets[s_practice_plan.count-1].at_ms+PRACTICE_COUNTDOWN_MS;
    if(!practice_queue(14,0,((uint32_t)s_practice_session<<16)|s_practice_plan.count) ||
       !practice_queue(14,2,final_at) || !practice_queue(14,1,0))return;
    const int64_t start_deadline=esp_timer_get_time()+2000000;
    while(s_score_playing&&practice_origin_get()==0&&esp_timer_get_time()<start_deadline)vTaskDelay(1);
    const int64_t origin=practice_origin_get();
    if(origin==0){ESP_LOGE(TAG,"practice START was not sent");practice_queue(14,3,0);return;}
    const int64_t ack_deadline=esp_timer_get_time()+800000;
    while(s_score_playing&&!s_practice_ack&&esp_timer_get_time()<ack_deadline)vTaskDelay(1);
    if(!s_score_playing){practice_queue(14,3,0);return;}
    if(!s_practice_ack){
        practice_queue(14,3,0);
        practice_feedback_t f={.session=s_practice_session,.flags=0x84,.last_result=0x80+PRACTICE_NO_RETURN};
        uint8_t packet[20];practice_feedback_ble(&f,0,packet);music_phone_uart_publish_raw(packet,sizeof(packet));
        ESP_LOGE(TAG,"practice start not acknowledged; check Y22 -> GPIO27");return;
    }
    ESP_LOGI(TAG,"practice %u targets, session %u, +/-150ms, no score NoteOn output",s_practice_plan.count,s_practice_session);
    uint16_t load=0,view=0;
    while(s_score_playing&&!s_practice_done&&(load<s_practice_plan.count||view<s_practice_plan.count)){
        const uint32_t load_at=load<s_practice_plan.count ?
            s_practice_plan.targets[load].at_ms+PRACTICE_COUNTDOWN_MS-PRACTICE_LOOKAHEAD_MS : UINT32_MAX;
        const uint32_t view_at=view<s_practice_plan.count ?
            s_practice_plan.targets[view].at_ms+PRACTICE_COUNTDOWN_MS : UINT32_MAX;
        if(load_at<=view_at){
            score_wait_until(origin,load_at);if(!s_score_playing||s_practice_done)break;
            practice_target_t *target=&s_practice_plan.targets[load++];
            if(!practice_queue(15,target->note,target->at_ms+PRACTICE_COUNTDOWN_MS))break;
        }else{
            score_wait_until(origin,view_at);if(!s_score_playing||s_practice_done)break;
            score_queue_view(2,0,NULL,0);++view;practice_view_target((uint16_t)(view+15U),15);
        }
    }
    if(s_score_playing&&!s_practice_done){
        score_wait_until(origin,final_at+200U);
        const int64_t deadline=esp_timer_get_time()+1000000;
        while(s_score_playing&&!s_practice_done&&esp_timer_get_time()<deadline)vTaskDelay(pdMS_TO_TICKS(10));
        if(!s_practice_done)ESP_LOGW(TAG,"no final FPGA feedback; check Y22 -> GPIO27 return wire");
    }
    if(!s_score_playing)practice_queue(14,3,0);
}

static void fpga_feedback_task(void *arg)
{
    (void)arg;
    if(CONFIG_SMK25_FPGA_UART_RX_GPIO<0||!smk25_uart_link_is_enabled()){vTaskDelete(NULL);return;}
    practice_parser_t parser={0};uint8_t bytes[128],sequence=0;
    for(;;){
        const int count=uart_read_bytes((uart_port_t)CONFIG_SMK25_FPGA_UART_PORT,bytes,sizeof(bytes),pdMS_TO_TICKS(100));
        for(int i=0;i<count;++i){
            practice_feedback_t f;
            if(!practice_parser_feed(&parser,bytes[i],&f))continue;
            uint8_t packet[20];practice_feedback_ble(&f,sequence++,packet);
            music_phone_uart_publish_raw(packet,sizeof(packet));
            if(s_practice_requested&&f.session==s_practice_session&&(f.flags&1U))s_practice_ack=true;
            if(s_practice_requested&&f.session==s_practice_session&&(f.flags&0x06U))s_practice_done=true;
        }
    }
}

static esp_err_t transmit_event(smk25_control_event_t *event,
                                uint8_t *next_sequence, uint8_t *next_phone_sequence)
{
    event->bytes[7] = (*next_sequence)++;
    const esp_err_t err = smk25_uart_link_send(event);
    if(err==ESP_OK&&(event->bytes[0]&0x3fU)==14U&&event->bytes[3]==1U){
        portENTER_CRITICAL(&s_fault_lock);s_practice_origin=esp_timer_get_time();portEXIT_CRITICAL(&s_fault_lock);
    }
    if (err == ESP_OK && (event->bytes[0] & 0x3fU) != SMK25_EV_SCORE_VIEW &&
        (event->bytes[0] & 0x3fU) != SMK25_EV_SCORE_LED &&
        (event->bytes[0] & 0x3fU) != 14U && (event->bytes[0] & 0x3fU) != 15U) {
        smk25_control_event_t phone_event = *event;
        phone_event.bytes[7] = (*next_phone_sequence)++;
        music_phone_uart_publish(&phone_event);
    }
    return err;
}

static void event_sender_task(void *arg)
{
    (void)arg;
    uint8_t next_sequence = 0;
    uint8_t next_phone_sequence = 0;
    smk25_pedal_refresh_t pedal_refresh = {0};
    smk25_control_event_t event;
    const TickType_t heartbeat = pdMS_TO_TICKS(CONFIG_SMK25_HEARTBEAT_MS);

    for (;;) {
        if (take_panic()) {
            ESP_LOGW(TAG, "safe all-notes-off: queued events discarded, overflow count=%lu",
                     (unsigned long)s_queue_overflow_count);
            xQueueReset(s_event_queue);
            /* The FPGA's safe-panic handling clears every active voice. */
            portENTER_CRITICAL(&s_bridge_lock);
            smk25_midi_bridge_all_notes_off(&s_bridges[SMK25_SRC_SMK25], &event);
            portEXIT_CRITICAL(&s_bridge_lock);
        } else if (xQueueReceive(s_event_queue, &event, heartbeat) != pdTRUE) {
            smk25_control_event_pack(&event, SMK25_EV_NOP, SMK25_SRC_SMK25, 0,
                                     SMK25_INST_PIANO, 0, 0, 0, 0, 0);
        }
        const esp_err_t err = transmit_event(&event, &next_sequence, &next_phone_sequence);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "UART event send failed: %s", esp_err_to_name(err));
            vTaskDelay(pdMS_TO_TICKS(10));
        } else if (!smk25_uart_link_is_enabled() && event.bytes[0] != 0x40U) {
            ESP_LOGD(TAG, "UART disabled; parsed event type=0x%02x seq=%u", event.bytes[0] & 0x3FU,
                     event.bytes[7]);
        }
        if (err == ESP_OK) {
            const uint32_t now_ms = (uint32_t)(xTaskGetTickCount() * portTICK_PERIOD_MS);
            smk25_pedal_refresh_observe(&pedal_refresh, &event, now_ms);
            smk25_control_event_t refresh;
            if (smk25_pedal_refresh_due(&pedal_refresh, now_ms, 200U, &refresh)) {
                const esp_err_t refresh_err = transmit_event(&refresh, &next_sequence, &next_phone_sequence);
                if (refresh_err != ESP_OK)
                    ESP_LOGE(TAG, "pedal state refresh failed: %s", esp_err_to_name(refresh_err));
            }
        }
    }
}

void app_main(void)
{
    ESP_ERROR_CHECK(smk25_protocol_self_test());
    ESP_ERROR_CHECK(score_store_init());
    ESP_ERROR_CHECK(smk25_uart_link_init());
    smk25_midi_bridge_init(&s_bridges[SMK25_SRC_SMK25], SMK25_SRC_SMK25);
    s_event_queue = xQueueCreateStatic(CONFIG_SMK25_EVENT_QUEUE_DEPTH,
                                       sizeof(smk25_control_event_t),
                                       s_queue_bytes, &s_queue_storage);
    ESP_ERROR_CHECK(s_event_queue != NULL ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(xTaskCreate(event_sender_task, "smk25_event_tx", 3072, NULL, 7, NULL) == pdPASS
                        ? ESP_OK : ESP_ERR_NO_MEM);
    ESP_ERROR_CHECK(xTaskCreate(score_playback_task, "score_local", 4096, NULL, 6,
                                &s_score_task) == pdPASS ? ESP_OK : ESP_ERR_NO_MEM);
    if(smk25_uart_link_is_enabled())
        ESP_ERROR_CHECK(xTaskCreate(fpga_feedback_task,"fpga_feedback",4096,NULL,5,NULL)==pdPASS?ESP_OK:ESP_ERR_NO_MEM);
    score_reset_view();
    const smk25_usb_midi_host_config_t usb_config = {
        .packet_cb = usb_packet_callback,
        .disconnect_cb = usb_disconnect_callback,
        .context = NULL,
    };
    ESP_ERROR_CHECK(smk25_usb_midi_host_start(&usb_config));
    const esp_err_t phone_err = music_phone_uart_start(phone_command_callback, NULL);
    if (phone_err != ESP_OK) {
        ESP_LOGE(TAG, "Phone UART start failed (%s); USB-MIDI/UART remain active", esp_err_to_name(phone_err));
    }
    ESP_LOGI(TAG, "ESP32-P4 SMK-25 + external SPP bridge started; UART output %s",
             smk25_uart_link_is_enabled() ? "enabled" : "disabled pending FPGA pin sign-off");
}
