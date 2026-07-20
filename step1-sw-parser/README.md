# Step 1 — ITCH 5.0 소프트웨어 레퍼런스 파서 (golden model)

SystemVerilog 디코더(step 2)를 만들기 전에 프로토콜을 손으로 익히고,
이후 cocotb 테스트벤치에서 기대값을 만들어 줄 golden model.

## 빌드 / 테스트

```sh
make test          # 합성 데이터 생성 + 파서 실행
```

- `gen_itch.py` — 알려진 시나리오(기대 BBO 시퀀스가 파일 상단 주석에 있음)로
  합성 ITCH 파일 생성. step 2 TB의 stimulus로도 사용.
  - `--mold test.mold` 추가 시 같은 시나리오를 **MoldUDP64 패킷 스트림**으로도
    출력 (step 3a stripper용). 하트비트 2회, 2-메시지 시퀀스 갭(MSFT 노이즈만
    유실이라 AAPL BBO 불변), End-of-Session 포함. 파일 포맷: UDP payload마다
    2B BE 길이 prefix. 패킷 플랜은 스크립트 상단 주석 참조. 생성 직후
    셀프체크(재파싱, seq 연속성, 갭 크기)를 통과해야 파일이 써진다.
- `itch_parser.c` — 파서 + 단일 종목 top-of-book. BBO가 바뀔 때마다 출력.
- `itch5.h` — 메시지 크기/오프셋 테이블. **step 2에서 SystemVerilog package로
  그대로 옮길 파일.**

## 실데이터로 돌리기

NASDAQ이 실제 하루치 캡처를 무료 공개한다 (압축 5–6 GB, 해제 시 10 GB+):

```sh
# https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/ 에서 파일명 확인 후
wget https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/<date>.NASDAQ_ITCH50.gz
./itch_parser <date>.NASDAQ_ITCH50.gz AAPL 1000000 > bbo.log   # 앞 100만 메시지만
```

하루치 전체는 3~4억 메시지 수준. stderr의 stats에서 메시지 타입 분포와
소프트웨어 처리율(M msg/s)을 확인해 두면 FPGA 대비 기준선이 된다.

## 프로토콜에서 확인한 것 → RTL 설계 포인트

1. **모든 메시지는 고정 길이이고, 길이는 첫 바이트(타입)로 결정된다.**
   → RTL 디코더는 타입 바이트를 본 순간 남은 길이를 알 수 있다. 상태머신이
   단순해지고, 메시지 경계에서 재정렬(realignment)만 처리하면 된다.

2. **모든 필드는 big-endian, 바이트 정렬.**
   → 필드 추출은 순수한 byte-lane select. 곱셈/시프트 없음.

3. **종목 필터는 8바이트 심볼 비교가 아니라 2바이트 stock locate로 한다.**
   locate는 헤더(offset 1)에 있어 모든 메시지에서 같은 위치.
   → 하드웨어에서는 구독 심볼들의 locate를 작은 CAM/LUT에 넣고 헤더만 보고
   조기 드롭(early drop) 가능. 'R'(directory) 메시지에서 locate를 학습.

4. **E/X/D/U 메시지에는 가격·사이드가 없다** — order reference로 기존 주문을
   찾아야 한다. → RTL에서 order table(해시 → U55C의 URAM/HBM)이 필수이며,
   이게 feed handler의 실제 난이도 포인트. 이 파서의 open-addressing 해시가
   그 참조 구현.

5. **'U'(replace)는 원 주문의 side/stock을 상속**하고, 'C'(exec with price)는
   체결가는 메시지의 가격이지만 **호가창에서 빠지는 위치는 원 주문의 표시
   가격**이다. 이런 코너 케이스가 RTL 검증 항목이 된다.

6. **파일 framing(2바이트 길이 prefix)과 와이어 framing(MoldUDP64)은 다르다.**
   실제 수신 경로: Ethernet → IP → UDP → MoldUDP64 헤더(session 10B +
   seq 8B + count 2B) → [len(2) + msg] × count.
   → RTL 파이프라인에 MoldUDP64 스트리퍼 스테이지가 하나 더 필요하고,
   sequence number 갭 검출(패킷 유실 → 스냅샷/재요청)도 여기서 한다.

## 다음 (step 2)

cocotb + Verilator 환경에서:
1. `itch5.h` → `itch5_pkg.sv` (타입/크기/오프셋 상수)
2. AXI-Stream(64bit @ ~322 MHz, U55C의 100G 경로 기준이면 512bit) 입력을 받는
   ITCH 디코더 모듈 — 타입별 필드를 병렬 추출해 내부 구조체 버스로 출력
3. 이 파서의 출력(BBO 로그)과 RTL 시뮬레이션 출력을 diff로 대조
