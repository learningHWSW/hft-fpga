# Step 4a — order table (order_ref 역방향 조회)

이 프로젝트의 두 번째 기술적 핵심. ITCH의 E/C/X/D/U 메시지는 `order_ref`만
들고 오므로, 오더북을 갱신하려면 `order_ref → {locate, side, price, qty}`를
O(1)에 되짚어야 한다. 이 테이블이 그 역방향 조회를 하고, 메시지마다 오더북이
움직일 가격 레벨을 book-delta로 내보낸다(step 4b의 price ladder 입력).

## 실행

```sh
make test              # xsim, 합성 test.itch (전 메시지 타입 A/F/E/C/X/D/U), AAPL locate 1
make test-verilator    # Verilator, 동일
make test-real         # 실데이터 50만 슬라이스, AAPL locate 13 (Verilator)
make test-real-xsim    # 위 xsim
```

golden은 `scripts/dump_book.py`(exact map). RTL의 book-delta 로그와 diff가 비면
PASS. TB는 추가로 **드롭 0**(테이블이 항상 제때 준비)·**overflow 0**(심볼에
맞게 사이징)을 확인한다.

## 설계 (측정 기반, data/FINDINGS.md §4)

- **d-way set-associative, mix 해시**: 전 종목 합산이면 단조 ref가 라운드로빈이라
  raw 하위비트로 충분하지만, **한 종목으로 필터링하면 그 종목 ref 부분집합이
  하위비트에서 군집**한다(raw 16b×4 = 24142 오버플로우 vs mix = 132). 그래서
  필터 테이블은 곱셈-시프트 mix 해시를 쓴다 — 전 종목 결과와 정반대인 측정 성과.
- **심볼 필터로 URAM 상주**: A/F는 `track_locate`와 locate가 같을 때만 진입.
  E/C/X/D/U는 ref로 조회 — 저장돼 있으면 곧 추적 종목. 전 종목 테이블은 8M+
  엔트리로 HBM 영역이지만, 종목을 걸러 URAM에 넣는다.
- **채택 크기**: `2^16 sets × 8-way + mix` = 524K 슬롯. AAPL 피크 27K → load ~5%.
  전일 AAPL 필터 측정에서 **오버플로우 0** 확인(FINDINGS §4.2). ≈10 MB URAM.
  저비용 대안 `16b×4 mix`(≈5 MB)는 하루 132건 딥오더 드롭(BBO 영향 무시 가능).
- **book-delta 출력**: 메시지당 `rem`(차감 레벨: D/E/C/X, U의 old) +
  `add`(증가 레벨: A/F, U의 new). U만 두 레벨을 건드리고 나머지는 하나.
  side·locate는 조회된 원 주문에서 상속(U의 side 상속, C가 체결가가 아니라
  저장된 호가에서 차감하는 것까지 golden과 일치).

## 상태 / 성능

- xsim (Vivado 2025.2): 합성 test.itch PASS (10 레코드, 전 타입), 실데이터
  50만 AAPL 슬라이스 PASS.
- Verilator: 합성 PASS, 실데이터 **500만 AAPL 슬라이스 PASS** (6740 레코드 —
  실제 A/F/E/X/D/U 포함, drop 0, overflow 0, miss는 타 종목 조회).
- **정확성 우선 FSM**: IDLE 수용 후 set access당 1사이클 → 단순 op 2 cy/msg,
  U 3 cy/msg. 2사이클 간격 + 같은 사이클 NBA writeback으로 메시지 간 same-set
  해저드가 포워딩 없이 사라진다. 64bit 입력에서 메시지가 여러 beat라 디코더가
  이보다 빨리 내보내지 않아 드롭이 없다.
- **다음(성능)**: II=1 파이프라인(read/modify/write + 포워딩, U는 dual-port로
  두 set 동시 접근). 정확성 기준선이 선 지금, 전후 처리율을 같은 리플레이로
  비교하는 별도 커밋으로.

## 구조

```
rtl/order_table.sv     — d-way set-assoc, 필터, book-delta 출력 (FSM)
tb/tb_order_table.sv   — file → itch_decoder(64b) → order_table, 드롭/overflow 검사
scripts/dump_book.py   — golden (exact map, 같은 레코드 포맷)
```

측정 도구는 step1에: `otable_sim.c`(오버플로우 스윕, `loc=N` 필터),
`sym_conc.c`(심볼별 동시성 피크), `itch_slice.py`(실데이터 슬라이스 추출).
