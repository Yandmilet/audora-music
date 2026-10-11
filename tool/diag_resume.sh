#!/system/bin/sh
# 决定性诊断：暂停→息屏→恢复，采样 PlaybackState(state/position/buffered)
# 判读：
#   BUFFERING(6) 且 buffered 不涨        = 网络死（但本地 90s+ 缓冲理应先响）
#   PLAYING(3)/READY 且 buffered>pos 但 pos 不动 = 渲染管线死
#   恢复瞬间 buffered 回落到 pos 附近     = 缓冲被系统/播放器清掉
LOG=/sdcard/diag_resume.txt
: > $LOG

snap() {
  echo "--- t+$1s $(date +%H:%M:%S) ---" >> $LOG
  dumpsys media_session | grep "state=PlaybackState" | head -1 >> $LOG
}

snap base0
cmd media_session dispatch pause
sleep 2
snap paused
input keyevent KEYCODE_SLEEP
echo "--- screen off, waiting 40s ---" >> $LOG
sleep 40
cmd media_session dispatch play
snap resume0
i=1
while [ $i -le 20 ]; do
  sleep 1
  snap $i
  i=$((i+1))
done
input keyevent KEYCODE_WAKEUP
echo "--- done ---" >> $LOG
