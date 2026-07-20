# Step 4b — price ladder / top-of-book (BBO)

step 4a order table의 book-delta 스트림(한 사이드의 rem/add 레벨)을 받아 L2
오더북을 유지한다 — 사이드·가격 레벨당 aggregate qty 하나. 최우선 호가(BBO:
best bid/ask 가격+수량)가 바뀔 때마다 출력하며, 그 시퀀스가 step 1 골든과
일치해야 한다. 이로써 `decoder → order_table → price_ladder` 전체 체인이
step 1 C 모델과 대조 검증된다.

## 실행

```sh
make test              # xsim, 합성 test.itch (AAPL locate 1, $150 밴드)
make test-verilator    # Verilator, 동일
make test-real         # 실데이터 500만 AAPL 슬라이스 (Verilator, $280 밴드)
make test-real-xsim    # 위 xsim
```

golden `scripts/dump_bbo.py`는 step 1 book 모델을 정규 포맷으로 재출력한 것.
독립 검증: `dump_bbo.py` 출력이 step 1 C 파서의 BBO와 byte 단위로 일치함을
확인함(합성·실데이터 모두). RTL BBO 로그와 golden diff가 비면 PASS.

## 설계 (측정 기반, data/FINDINGS.md §3)

- **가격 → 레벨 인덱스**: `idx = (price - cfg_base) / TICK`. TICK=100($0.01)은
  컴파일 상수라 합성 시 나눗셈이 곱셈-시프트로 degrade. `cfg_base`는 종목별로
  소프트웨어가 설정하는 밴드 시작가(재중심화 훅, PLAN §2.1).
- **고정 밴드 LEVELS 레벨**: 밴드 밖 가격은 드롭 + `oob_cnt`. **oob는 오류가
  아니라 설계**(PLAN §2.1: 밴드 벗어난 딥레벨 드롭). oob 가격은 BBO에서 멀어
  최우선이 되지 않으므로 BBO diff가 그대로 통과 — diff가 정확성 게이트다.
  실측: AAPL 500만 슬라이스에서 oob 465건(전부 딥/스텁 호가, BBO 불변).
- **best 탐색**: 사이드별 occupancy 비트맵(레지스터) 위 priority scan —
  best bid=최고 점유 레벨, best ask=최저. 조합 논리라 매 갱신 즉시.
- **L2로 시작**: 레벨당 `{qty 합}`만. 레벨당 주문 수·근사 L3는 후속.

## 상태 / 성능

- xsim (Vivado 2025.2): 합성 PASS, 실데이터 50만 AAPL PASS.
- Verilator: 합성 PASS, 실데이터 **500만 AAPL PASS** (1779 BBO 업데이트,
  drop 0, overflow 0). 전 체인이 step 1 C 모델과 일치.
- **정확성 우선 FSM**: 레코드당 rem/add/eval로 3사이클. 입력이 디코더·order
  table로 율속되어 드롭 0. best 탐색을 파이프라인화하고 qty를 BRAM(등록 read)로
  옮기는 최적화는 후속.

## 구조

```
rtl/price_ladder.sv    — L2 사다리, occupancy 기반 BBO, oob 카운터 (FSM)
tb/tb_price_ladder.sv  — file → decoder → order_table → price_ladder 체인
scripts/dump_bbo.py    — golden (step 1 book 모델, 정규 포맷; step1과 교차검증됨)
```
