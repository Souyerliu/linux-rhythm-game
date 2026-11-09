# Far in the blue sky — Easy

来源：用户提供的 `../saikoro - Far in the blue sky.mid`。
时长约 3 分 5 秒，148 BPM，268 个单点音符，无双押、无长按，最短间隔 304 ms。

主段跟随 `electro-main` 主旋律轨道，以每拍最多一个音符进行简化。
前奏和尾奏参考 `bass` 轨道，每两拍最多一个音符；首个音符约在 3.45 秒出现。
音符保留原 MIDI 的实际起音时间，因此包含少量切分节奏。

```bash
./game.sh songs/far-in-the-blue-sky-easy/chart.csv
./editor.sh songs/far-in-the-blue-sky-easy/chart.csv
```

BGM 保留 MIDI 的所有轨道，由 FluidSynth 和 GM 音色库合成。首次播放会生成 WAV 缓存。
通用 GM 音色与原作品的音色可能不同，但不会裁剪 MIDI 的配器轨道。

生成命令（目标文件必须尚不存在，避免覆盖手动编辑）：

```bash
bash tools/midi_import.sh 'songs/saikoro - Far in the blue sky.mid' \
  --track 1 --support-track 2 --output songs/far-in-the-blue-sky-easy/chart.csv
```
