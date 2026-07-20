# Step 2 — SystemVerilog ITCH 디코더 + 셀프체킹 시뮬레이션

xsim(Vivado/Vitis)이 1순위 플로우. Verilator는 Vivado 없는 환경용 보조.

## 실행

```sh
# Vivado/Vitis 환경 (settings64.sh source 후)
make test

# Vivado 없는 환경
make test-verilator
```

두 플로우 모두: step1의 `gen_itch.py`로 만든 test.itch를 TB가 AXI-Stream으로
주입 → 디코더 출력이 `decode_rtl.log`로 기록 → `scripts/dump_itch.py`(golden)
출력과 **diff가 비면 PASS**.

## 구조

```
rtl/itch5_pkg.sv     — 오프셋/크기 상수 + itch_msg_t (step1 itch5.h의 SV 미러)
rtl/itch_decoder.sv  — AXI-Stream(64bit) 입력, itch_msg_t + valid 펄스 출력
tb/tb_itch_decoder.sv— 파일 주입 드라이버 + 캐노니컬 로그 모니터
scripts/dump_itch.py — 같은 파일에서 같은 포맷의 golden 로그 생성
```

## 설계 결정 (현재 상태)

- **인터페이스**: 메시지당 1 packet(tlast) AXI-Stream. 프레이밍(MoldUDP64 또는
  파일의 길이 prefix) 제거는 상류(step 3) 담당.
- **store-then-decode**: tlast 다음 사이클에 전체 필드 병렬 추출 + valid 펄스.
  기능 검증용으로 단순 명확. 지연 최적화(마지막 필요 필드 도착 즉시 발화하는
  cut-through)는 파이프라인이 완성된 뒤에.
- **s_tready = 상수 1**: 시장 데이터 경로는 절대 wire를 backpressure하지
  않는다. 하류가 느리면 FIFO로 흡수하고, 넘치면 드롭+갭 처리.
- **길이 검증**: 수신 길이 ≠ 스펙 길이면 `m_len_err` — 상류 프레이밍 버그나
  피드 이상 검출용.

## xsim 사용 팁

- 파형 보려면: `xelab -debug typical` 상태이므로
  `xsim tb_itch_decoder_sim -gui -testplusarg itch=...` 로 열면 됨.
- 회귀 돌릴 때는 `-runall`(배치)이 빠름. `-R` 옵션으로 xelab과 합칠 수도 있음.

## 다음 (step 3+)

1. 디코더를 512bit(100G CMAC) 폭으로 일반화 — 핵심 난제: 한 beat에 여러
   메시지가 끝나고 시작하는 realignment. 현재 64bit 버전이 그대로
   레퍼런스가 됨.
2. MoldUDP64 스트리퍼(sequence gap 검출 포함) + UDP/IP/Ethernet 파서 결합.
3. order table + top-of-book 엔진 (step1 C 모델이 golden).
