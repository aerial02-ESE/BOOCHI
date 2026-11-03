package com.gowin.musiccontroller

/** Cumulative device snapshot; recovery does not depend on receiving every notification. */
data class PracticeTelemetry(val session: Int,val flags: Int,val sequence: Int,
    val total: Int,val hits: Int,val wrong: Int,val misses: Int,val elapsedMs: Long,
    val lastNote: Int,val result: Int) {
    val active get() = flags and 1 != 0
    val finished get() = flags and 2 != 0
    val error get() = flags and 4 != 0
    val espRejected get() = flags and 128 != 0
    val judged get() = hits + misses + wrong
    val liveAccuracy get() = if(judged==0) 0.0 else 100.0*hits/judged
    val songAccuracy get() = if(total+wrong==0) 0.0 else 100.0*hits/(total+wrong)
    val progress get() = if(total==0) 0.0 else 100.0*(hits+misses)/total
    companion object {
        fun crc(bytes: ByteArray,length: Int=bytes.size): Int {
            var crc=0xffff
            for(i in 0 until length){
                crc=crc xor ((bytes[i].toInt() and 255) shl 8)
                repeat(8){crc=if(crc and 0x8000!=0) ((crc shl 1) xor 0x1021) and 65535 else (crc shl 1) and 65535}
            }
            return crc
        }
        fun decode(bytes: ByteArray): PracticeTelemetry {
            require(bytes.size==20 && bytes[0].toInt() and 255==0x50){"成绩包格式错误"}
            fun u(i:Int)=bytes[i].toInt() and 255
            fun u16(i:Int)=(u(i) shl 8) or u(i+1)
            require(crc(bytes,18)==u16(18)){"成绩包CRC错误"}
            val value=PracticeTelemetry(u(1),u(2),u(3),u16(4),u16(6),u16(8),u16(10),
                (u(12).toLong() shl 24) or (u(13).toLong() shl 16) or (u(14).toLong() shl 8) or u(15).toLong(),u(16),u(17))
            require(value.total<=4096 && value.hits+value.misses<=value.total && value.flags and 0x60==0)
            return value
        }
    }
}

object PracticePlan {
    /** Match the uploaded representation, including duplicate-note suppression. */
    fun targets(score: MusicScore): List<Pair<Int,Int>> {
        val records=ScoreTransfer.encode(score)
        val result=ArrayList<Pair<Int,Int>>()
        val seen=HashSet<Long>()
        var left=0
        for(record in records){
            if(record[0].toInt() and 255!=ScoreTransfer.RECORD)continue
            val flags=record[1].toInt() and 255
            if(flags and 0x20==0 || flags ushr 6==2)continue
            val note=record[4].toInt() and 255
            if(note !in 21..108)continue
            val at=((flags and 0x1f) shl 16) or ((record[2].toInt() and 255) shl 8) or (record[3].toInt() and 255)
            if(!seen.add((at.toLong() shl 8) or note.toLong()))continue
            require(result.size<4096){"跟弹曲谱超过4096个目标音"}
            while(left<result.size && at-result[left].first>1200)left++
            require(result.size-left<56){"乐谱过密：1.2秒内超过56个目标音，请简化乐段或选择单独钢琴轨"}
            result.add(at to note)
        }
        require(result.isNotEmpty()){"没有可跟弹的88键旋律音符（鼓轨不计入）"}
        return result
    }
}
