# Step 3b — 512비트 MoldUDP64 재정렬 스플리터

100G CMAC 폭(512비트 = 64바이트/beat)에서 MoldUDP64 payload를 받아 ITCH
메시지 단위로 **재정렬(realignment)**해 1 msg/cycle로 내보낸다. 한 beat 안에서
메시지가 끝나고 다음이 시작하며(beat당 최대 3개 경계), 메시지가 beat 경계를
넘나든다 — 이 재정렬이 step 3b의 기술적 핵심이다. 출력은 step 2 디코더
입력 규약 그대로라 `itch_decoder #(.DATA_W(512))`를 무변경 재사용한다.

## 실행

```sh
make test              # xsim, 합성 test.mold (gap+dup+hb+eos 포함)
make test-verilator    # Verilator, 동일
make test-real         # 실데이터 100만 msg (Verilator)
make test-real-xsim    # 실데이터 100만 msg (xsim)
```

실데이터는 BinaryFILE 포맷이라 그대로는 재정렬을 자극하지 못한다.
`step1-sw-parser/itch2mold.py`가 실메시지를 다중 메시지 MoldUDP64 패킷으로
재포장(패킷당 1~8개 순환 + 주기적 하트비트 + EOS)해 경계가 beat 안 여러
오프셋에 흩어지게 만든다. golden은 step 3a의 `dump_mold.py`(폭 무관)를 그대로.

## 재정렬 코어

2-beat(128바이트) 바이트 윈도우를 flat 벡터로 유지. **매 사이클 동시에**:
- `consume`: 앞에서 제거하는 바이트 (완결 메시지 `2+len`, 헤더 20B, 또는 앞이
  미완이면 0)
- `accept`: 이번 사이클 consume 후 자리가 남으면 입력 beat 1개를 꼬리에 append
  (`s_tready`가 이 여유를 반영)

둘 다 배럴시프트로 같은 사이클에 처리 → 한 beat에 메시지 2~3개가 겹쳐도
출력이 **1 msg/cycle 유지**. 이게 입력 FIFO 사이징(최악 76 msgs,
[data/FINDINGS.md](../data/FINDINGS.md))과 맞물린다. 앞이 미완이면 자동으로
`vcnt ≤ 52 < 64`라 항상 beat 수용 여유가 있어 진행이 보장되고, 점유는 128바이트를
넘지 않는다(윈도우 불변식).

시퀀스 추적(gap/hb/dup/eos)은 step 3a와 동일한 수신자 모델이며 `dump_mold.py`와
일치. dup 데이터 패킷은 헤더+메시지 바이트를 소비하되 출력 억제(DROP 상태).

## 설계 노트

- **패킷 경계는 framing으로**: 헤더 MsgCount + 메시지 길이 prefix로 경계를 알아
  `s_tlast`는 datapath에서 안 쓴다(포트만 유지). 바이트 스트림은 자기서술적.
- **모든 ITCH 메시지 ≤ 50B < 64B** → 메시지 1개 = beat 1개 = cycle 1개. 출력은
  좌측 정렬(메시지 byte0이 `m_tdata[7:0]`), `m_tkeep`=길이, `m_tlast`=매 beat 1.
- **디코더 무변경 재사용**: `DATA_W=512`로 인스턴스화하면 단일 beat를 모아
  다음 사이클 디코드. 연속(back-to-back) tlast beat도 정상(디코드가 beat 다음
  사이클, mbuf는 타입별 필드 범위만 읽음).
- **로그 정렬**: 스플리터는 메시지·이벤트를 같은 스테이지에 레지스터하지만,
  메시지는 디코더(2사이클)를 더 거친다. TB가 이벤트 로깅을 그 지연만큼 늦춰
  단일 스트림 순서를 복원한다(`EV_DELAY=2`). RTL 자체는 무관.
- **xsim 이식성 함정(디버깅으로 발견)**: 연속 할당에서 모듈 신호 `win`을
  인자 아닌 방식으로 읽는 함수(`assign msglen = w_be16(0)`)는 xsim에서 `win`이
  감도 목록에 없어 재평가되지 않아 `msglen`이 X로 고정 → 무한 스톨. Verilator는
  함수를 인라인해 우연히 동작. 수정: 연속 할당은 직접 비트선택
  (`{win[7:0], win[15:8]}`). **교훈: 연속 할당용 함수는 인자에만 의존시킬 것.**
  TB에 스톨 워치독을 상설화해 이런 행을 즉시 잡는다.

## 상태

- **xsim (Vivado 2025.2)**: 합성 test.mold PASS, 실데이터 5만 msg PASS
- **Verilator**: 합성 PASS, 실데이터 100만 msg PASS (2019-12-30)
- 두 플로우 모두 gap/dup/hb/eos + 512b 재정렬 검증. len_err·frame_err 0.
