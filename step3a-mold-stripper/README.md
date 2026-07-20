# Step 3a — MoldUDP64 스트리퍼 + 시퀀스 갭 검출

MoldUDP64 패킷(UDP payload)을 받아 ITCH 메시지 단위 AXI-Stream으로
재프레이밍하고, 시퀀스 갭/하트비트/중복/EOS를 검출한다. 출력은 step 2
디코더 입력 규약(메시지당 tlast) 그대로 — TB에서 실제로 디코더를 체인해
통합 검증한다.

## 실행

```sh
make test            # xsim (Vivado/Vitis 환경)
make test-verilator  # Vivado 없는 환경
```

test.mold가 없으면 step 1의 `gen_itch.py --mold`로 자동 생성된다.
시나리오: 하트비트 2회, 2-메시지 갭(seq 11–12 유실), 중복 패킷 1회, EOS.

## 구조

```
rtl/mold_stripper.sv   — 스트리퍼 (store-and-forward, 64bit 레퍼런스)
tb/tb_mold_stripper.sv — 파일 주입 → 스트리퍼 → step2 itch_decoder 체인
scripts/dump_mold.py   — golden (메시지 라인은 step2 dump_itch.fmt_msg 재사용)
```

로그 한 파일에 디코드 라인과 이벤트 라인(`GAP expected=.. got=.. missing=..`,
`HB seq=..`, `EOS seq=..`)이 스트림 순서대로 섞여 기록되고, golden과 diff가
비면 PASS. 갭 이벤트는 항상 해당 패킷의 메시지들보다 먼저 나온다.

## 설계 결정

- **시퀀스 추적**: reset 시 expected=1. 갭(seq > expected)은 데이터/하트비트
  모두에서 검출 — 펄스 + `gap_total` 누적 후 새 seq에서 계속. 중복
  (seq < expected)은 패킷 통째로 드롭 + `dup_cnt`. **재전송 요청/리와인드는
  SW 몫** (PLAN.md §0-5).
- **store-and-forward + s_tready**: 패킷 전체 버퍼 후 메시지 워크. 드레인
  중 s_tready=0. 메시지당 tlast 재프레이밍은 패딩 때문에 입력보다 최대
  ~1.14× 느릴 수 있어, 실제 와이어 뒤에는 흡수 FIFO(오버플로우 드롭+카운터)가
  필수 — MAC을 backpressure하지 않는다는 원칙 그대로.
- **이 모듈은 behavioral 레퍼런스**: 바이트 단위 랜덤 액세스 버퍼라 합성
  뮤스가 크다. 512bit 라인레이트 버전(step 3b)이 이걸 golden 삼아 대체한다.
- **frame_err_cnt**: 헤더 미달/길이 불일치/버퍼 초과 등 프레이밍 이상 카운터.
  정상 스트림에서 0이어야 하고 TB가 마지막에 확인한다.

## 상태

- xsim (Vivado 2025.2): PASS
- Verilator: PASS
- 둘 다 19/21 msgs 전달, gap_total=2, dup=1, frame_err=0, EOS 검출
