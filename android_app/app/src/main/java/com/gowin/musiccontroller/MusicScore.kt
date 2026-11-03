package com.gowin.musiccontroller

import org.json.JSONArray
import org.json.JSONObject

data class ScoreNote(val at: Int, val note: Int, val velocity: Int, val duration: Int,
                     val instrument: Int = 0)
data class ScorePedal(val at: Int, val value: Int)

/** 与 phone_app/example-score.json 兼容的有界 MIDI 乐谱，不包含音频波形。 */
data class MusicScore(val title: String, val notes: List<ScoreNote>,
                      val pedals: List<ScorePedal> = emptyList()) {
    init {
        require(title.length <= 80 && notes.size <= 4096) { "乐谱过大" }
        notes.forEach {
            require(it.at in 0..600_000 && it.note in 0..127 &&
                it.velocity in 1..127 && it.duration in 1..30_000 &&
                it.instrument in 0..2) { "乐谱音符范围错误" }
        }
        require(pedals.size <= 4096 && pedals.all { it.at in 0..600_000 && it.value in 0..127 }) {
            "乐谱踏板事件范围错误"
        }
    }

    fun toJson(): String {
        val array = JSONArray()
        notes.forEach {
            array.put(JSONObject().put("at", it.at).put("note", it.note)
                .put("velocity", it.velocity).put("duration", it.duration)
                .put("instrument", it.instrument))
        }
        val pedalArray = JSONArray()
        pedals.forEach { pedalArray.put(JSONObject().put("at", it.at).put("value", it.value)) }
        return JSONObject().put("version", 1).put("title", title)
            .put("notes", array).put("pedals", pedalArray).toString(2)
    }

    companion object {
        private fun exactInt(obj: JSONObject, key: String): Int {
            val value = obj.get(key)
            require(value is Number && value.toDouble().isFinite() &&
                value.toDouble() == value.toInt().toDouble()) { "$key 必须是整数" }
            return value.toInt()
        }

        fun parse(json: String): MusicScore {
            require(json.length <= 524_288) { "乐谱文件超过 512 KB" }
            val root = JSONObject(json)
            require(exactInt(root, "version") == 1) { "仅支持 v1 乐谱" }
            val array = root.getJSONArray("notes")
            require(array.length() <= 4096) { "乐谱最多 4096 个音符" }
            val notes = (0 until array.length()).map { i ->
                val obj = array.getJSONObject(i)
                ScoreNote(exactInt(obj, "at"), exactInt(obj, "note"),
                    exactInt(obj, "velocity"), exactInt(obj, "duration"),
                    if (obj.has("instrument")) exactInt(obj, "instrument") else 0)
            }
            val pedalArray = root.optJSONArray("pedals") ?: JSONArray()
            require(pedalArray.length() <= 4096) { "乐谱踏板事件过多" }
            val pedals = (0 until pedalArray.length()).map { i ->
                val obj = pedalArray.getJSONObject(i)
                ScorePedal(exactInt(obj, "at"), exactInt(obj, "value"))
            }
            return MusicScore(root.optString("title", "未命名乐谱").take(80), notes, pedals)
        }
    }
}
