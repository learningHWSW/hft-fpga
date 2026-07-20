# 개선된 계획 — ITCH 틱-투-트레이드 (U55C, SystemVerilog RTL)

원래 계획서(HLS 기반 초안)를 현재 리포 상태에 맞게 재작성한 버전.
step 1(C golden parser)·step 2(64bit SV 디코더, golden diff PASS)는 완료.

## 0. 원안 대비 바뀐 것 (개선 포인트)

| # | 원안 | 개선 | 근거 |
|---|---|---|---|
| 1 | HLS(`hls::stream`, `DATAFLOW`, II=1) 기준 서술 | SV RTL 기준으로 재기술. 성능 지표는 "II"가 아니라 **msg/cycle @ 322.27 MHz(CMAC 512bit 클록)** | 프로젝트가 RTL로 확정됨 (step 2 완료) |
| 2 | 심볼 → 해시 테이블 조회 | **stock locate(2B)를 배열 인덱스로 직접 사용** — 모든 메시지 헤더에 있고, 하루 동안 조밀한 소정수. 심볼 해시 자체가 불필요 | step 1에서 프로토콜 확인으로 발견 |
| 3 | 오더북에 심볼 해시 + order_ref 해시 2중 조회 | 해시는 **order_ref 하나만**. `hash(order_ref) → {locate, side, level_idx, qty}` | 위 2번의 결과 |
| 4 | 파서가 메시지당 1개 처리, 폭 언급 없음 | **처리량 수치 명시**: 최악(전부 'D' 19B+len 2B)은 512b beat당 ~3 msg 경계. 단, 실제 피크는 수 M msg/s 수준 → **1 msg/cycle 스플리터 + 입력 FIFO(버스트 흡수) + overflow 카운터**. FIFO 깊이는 실데이터 버스트 분포를 측정해서 결정 | 322 M msg/s(1 msg/cycle)는 실제 피드 대비 두 자릿수 여유. beat-내 다중 경계는 순간치일 뿐 |
| 5 | 갭 리커버리 언급만 | 확정: **HW는 갭 검출 + 카운터 + 세션 리셋만, 재전송/리와인드는 SW** (hot path 아님) | 원안 권장을 결정으로 승격 |
| 6 | HBM 활용을 전제 | **hot path는 URAM 우선, HBM은 보류**. 추적 심볼을 필터링하면 order table이 on-chip에 들어감. 전 종목 추적이 필요해질 때만 HBM 검토 — 실데이터에서 동시 미체결 주문 수 피크를 먼저 측정 | HBM 레이턴시(수백 ns)는 시장데이터 hot path에 부적합 |
| 7 | Stage A/B/C 구분 (PCIe DMA 스테이지 포함) | **PCIe 주입 스테이지 축소**: 시뮬레이션에서 실데이터 리플레이가 이미 되므로(step 1 실데이터 파이프), PCIe는 "호스트 리포팅/제어 경로"로만. 데이터 주입 경로로서의 Stage B는 삭제 | AF_XDP→DMA→FPGA 주입은 검증 가치 대비 공수 큼. TB 리플레이가 같은 걸 더 정확히 검증 |
| 8 | 'U'(Replace) 처리를 단순 취소+추가로 서술 | 'U'는 **stock/side 필드가 없음** → old ref 조회로 상속. 'E'/'X'/'D'도 조회 필수. **book 엔진의 사이클 예산은 'U'(조회+삭제+삽입, 해시 2연산) 기준으로 산정** | 스펙 재확인. 처리량 병목이 여기서 결정됨 |
| 9 | 검증 방법 산발적 서술 | **golden diff 패턴을 전 단계에 일관 적용**: 각 step마다 C/Python golden이 캐노니컬 로그 생성, RTL TB가 같은 포맷 출력, diff 빈 것이 PASS. 실데이터 앞 N백만 msg 리플레이를 회귀로 고정 | step 2에서 이미 검증된 방식 |

## 1. 목표 아키텍처

```
QSFP28 ──► CMAC(100G) ──► eth/ip/udp 파서 ──► MoldUDP64 스트리퍼 ──► msg 스플리터
              512b@322M      (필터+체크섬)       (seq gap 검출)        (경계 재정렬)
                                                                          │ itch raw msg
                                                                          ▼
   호스트(PCIe) ◄── BBO/이벤트 리포트 ◄── top-of-book 엔진 ◄── order table ◄── itch 디코더
                                          (locate별 ladder)    (ref 해시, URAM)   (step2 확장)
                                                │
                                                ▼ 트리거
                                          OUCH 빌더 ──► TX (스트레치, 세션은 SW)
```

- 시장데이터 경로는 전 구간 **backpressure 없음**(tready=1). 흡수는 FIFO, 초과는 드롭+카운터. (step 2에서 확립한 원칙)
- 심볼 필터는 locate 기반 bitmap (R 메시지로 SW가 설정, 섀도우/커밋 레지스터).

## 2. 단계별 계획

### Step 3a — MoldUDP64 스트리퍼 + 메시지 스플리터 (64bit 먼저)
- MoldUDP64 헤더(20B) 제거, MsgCount 루프, 하트비트 처리, **seq gap 검출**(카운터 + SW 인터럽트/플래그).
- 길이 prefix 기반으로 메시지 경계 분할 → step 2 디코더 인터페이스(msg당 tlast)로 출력.
- gen_itch.py에 MoldUDP64 래핑 모드 추가 (갭·하트비트·beat 경계 걸침 케이스 포함).
- **DoD**: 갭/하트비트/경계 케이스 포함 golden diff PASS (xsim + Verilator).

### Step 3b — 512bit 폭 확장 + 재정렬 (기술적 핵심 1) ✅
- 스플리터를 512bit로 일반화: 한 beat 안에서 메시지가 끝나고 시작하는 재정렬, beat당 최대 3개 경계. → [step3b-splitter/rtl/mold_splitter.sv](step3b-splitter/rtl/mold_splitter.sv). 2-beat(128B) 윈도우 + 배럴시프트로 fill/emit 동시 처리해 **1 msg/cycle 유지**.
- 설계: 1 msg/cycle 출력 + 앞단 elastic FIFO. **FIFO 깊이 확정(측정 완료, [data/FINDINGS.md](data/FINDINGS.md))**: 전일 최악 백로그 76 msgs / 2356 B → 입력 FIFO **256-엔트리(2^8)** 또는 512b 폭 **64-deep beat FIFO(4 KB)**. 백로그 ≥2가 1%뿐이라 대부분 거의 빈 상태. (FIFO 인스턴스화는 CMAC 결합 시 step 5에서.)
- 디코더(step 2)는 폭만 맞추면 재사용 — `itch_decoder #(.DATA_W(512))` 무변경.
- **DoD 달성**: 실데이터 리플레이(2019-12-30) diff PASS — Verilator 100만 msg, xsim 5만 msg, 합성 test.mold(gap/dup/hb/eos)는 두 플로우 모두. 실데이터는 BinaryFILE라 [itch2mold.py](step1-sw-parser/itch2mold.py)로 다중 메시지 MoldUDP64 재포장해 재정렬 자극.

### Step 4a — order table (기술적 핵심 2) ✅
- `hash(order_ref) → {locate, side, price, qty}` d-way set-associative, URAM. → [step4a-order-table/rtl/order_table.sv](step4a-order-table/rtl/order_table.sv). 메시지당 book-delta(rem/add 레벨) 출력.
- **측정으로 설계점 확정** ([data/FINDINGS.md](data/FINDINGS.md) §4): 전 종목은 HBM(8M+ 엔트리, 어떤 구성도 오버플로우 0 불가). **심볼 필터 → URAM**. 반전 발견: 필터 테이블은 **raw가 아니라 mix 해시** 필요(단일 종목 ref가 하위비트에서 군집; raw 16b×4=24142 vs mix=132 오버플로우). 채택 `2^16×8 + mix` → AAPL 전일 오버플로우 0.
- **검증 완료**: 합성 test.itch(전 op 타입) xsim+Verilator PASS, 실데이터 AAPL 슬라이스(500K xsim, 5M Verilator, 실제 U/X 포함) PASS. drop 0, overflow 0.
- **성능(다음)**: 현재 정확성 우선 FSM(2 cy/msg, U 3). II=1 파이프라인(read/modify/write + 포워딩, U dual-port)이 후속 — 전후 처리율 비교.
- 'U' 처리(조회→삭제→삽입)가 최다 사이클 — 이걸 기준으로 msg당 처리 사이클 예산 확정.
- golden: step 1 파서를 확장해 order table 연산 로그(insert/erase/modify + 결과) 출력.
- **DoD**: 실데이터 리플레이에서 테이블 상태 diff PASS, 충돌/점유율 리포트.

### Step 4b — top-of-book / price ladder ✅
- 가격 사다리(레벨당 aggregate qty, L2), occupancy 비트맵 위 priority scan으로 BBO. → [step4b-book/rtl/price_ladder.sv](step4b-book/rtl/price_ladder.sv). `cfg_base`로 밴드 시작가 설정(재중심화 훅), 밴드 이탈은 드롭 + `oob_cnt`(저빈도 경로 빈도 측정 — AAPL 500만서 465건, 전부 딥/스텁, BBO 불변).
- **golden**: [dump_bbo.py](step4b-book/scripts/dump_bbo.py) = step 1 book 모델 정규 포맷. step 1 C 파서 BBO와 byte 단위 교차검증(합성·실데이터).
- **DoD 달성**: `decoder→order_table→price_ladder` 전 체인이 AAPL BBO 시퀀스에서 diff PASS — 합성 xsim+Verilator, 실데이터 xsim 50만 + Verilator 500만(1779 BBO). drop 0, overflow 0.
- **성능(다음)**: 정확성 우선 FSM(3 cy/record). best 탐색 파이프라인화 + qty BRAM화가 후속. 레이턴시 실측·L3(레벨당 고정 슬롯)도 이후.

### Step 5 — U55C 실보드
- CMAC + verilog-ethernet(또는 벤더 IP)로 UDP/IP 수신, IGMP 조인. U55C 예제 디자인 호환성 사전 확인.
- 호스트 리포팅: BBO 변화·갭 이벤트를 QDMA로 스트리밍, 제어 레지스터(심볼 bitmap, 파라미터)는 섀도우/커밋.
- **DoD**: 리플레이 장비(또는 tcpreplay 100G) → 와이어 수신 → BBO가 시뮬레이션과 일치. MAC 수신~BBO 갱신 레이턴시 실측 (사이클 카운터, ns 환산).

### Step 6 (스트레치) — OUCH 발사
- 세션(SoupBinTCP 수립·재전송·하트비트)은 SW, **FPGA는 수립된 세션의 seq/ack를 섀도우 레지스터로 받아 hot path 패킷 조립·발사만**.
- 트리거: 4b의 BBO 이벤트 → 비교기 → 미리 스테이징된 주문 템플릿.
- 안 되더라도 설계 문서로 남김 (원안 §8 방침 유지).

## 3. 측정 체크리스트 (전 단계 공통)

- 각 step 완료 시: 레이턴시 p50/p99(사이클→ns), 자원(LUT/FF/BRAM/URAM), 최대 클록.
- 실데이터 기준선: step 1 SW 처리율(M msg/s) 대비 RTL 배수.
- 드롭/갭/오버플로우 카운터는 모든 모듈에 표준으로 내장.
- cut-through 디코드(마지막 필요 필드 도착 즉시 발화)는 **전체 파이프 완성 후** 별도 최적화 커밋으로 — 개선 전후 레이턴시를 같은 리플레이로 비교.

## 4. 우선순위

1. **3a → 3b → 4a → 4b** 순서 고정. 4a(order table)가 이 프로젝트의 기술적 핵심 — 여기까지가 완결된 포트폴리오.
2. Step 5는 보드 접근 가능 시점에.
3. Step 6은 시간 남을 때. 문서만으로도 가치 있음.
