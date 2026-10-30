# TX6Mac

TX-6를 맥의 프로그램별 음량·EQ 컨트롤러로 사용하는 네이티브 macOS 앱입니다. 일반 창과 상단 메뉴바에서 조절하며, 맥 스피커·AirPlay·USB TX-6 중 오디오 출력을 선택합니다.

## 실행

`TX6Mac.app`을 실행합니다. 첫 실행 안내에서 오디오 처리와 권한을 확인하고 직접 믹서를 시작합니다. 이후에는 설정의 ‘믹서 자동 시작 및 연결 복구’가 켜져 있으면 앱 실행·기기 재연결 때 믹서를 시작하거나 복구합니다. 이 옵션은 기본으로 켜져 있으며, 사용자가 믹서를 명시적으로 중지한 실행 중에는 자동 재개하지 않습니다. 설정에서 한국어·영어·일본어 또는 시스템 언어를 선택할 수 있습니다. 앱 내부 언어를 바꿔도 macOS 권한 팝업 언어는 시스템이 선택합니다. 믹서를 시작하면 소리를 출력하는 앱을 자동으로 인식합니다. 1번은 시스템 효과음에 고정되고, 2~6번에 앱·Chrome 탭이 배치됩니다. 한 번 배치된 앱·탭은 소리가 멈춰도 같은 채널을 유지하며, 종료된 앱의 빈자리에 새 재생 앱을 넣습니다. 음량·EQ·음소거는 물리 채널에 고정되어 앱 배치가 바뀌어도 다른 채널로 이동하지 않습니다. 5개를 넘는 앱은 MASTER로 조절합니다. 시스템 오디오 접근을 요청하면 macOS 안내에서 허용해야 앱별 음량·EQ 처리가 가능합니다. 오디오를 파일로 녹음하거나 외부 서버로 전송하지 않습니다.

트랙에 지정하지 않은 프로그램도 전체 음량·전체 음소거의 영향을 받습니다. 창을 닫아도 메뉴바에서 계속 실행되며, 메뉴바의 종료를 선택하면 오디오 탭을 해제합니다. 잠자기 중에는 오디오 처리를 중지하고, 깨어나면 이전에 실행 중이던 믹서를 선택한 출력으로 복구합니다. 선택한 출력이 없으면 원음을 복구하며 다른 출력으로 임의 전환하지 않습니다. 이 앱은 기존 시스템 기본 출력 설정을 바꾸지 않고, 실행 중 캡처한 소리를 선택한 장치로 전달합니다.

## TX-6 설정

SHIFT를 누른 채 SELECT를 눌러 시스템 메뉴로 들어갑니다.

| 항목 | 설정 |
|---|---|
| MIDI → CTRL | OUT |
| BLE | 무선 조작 시 ACCEPT |
| USB | 2 CH |
| SYNTH / DJ | OFF |
| SOLO | MUTE |

USB는 오디오와 MIDI를 전달합니다. Bluetooth LE는 MIDI 조작만 전달하므로 Bluetooth 연결 상태에서 듣는 소리는 맥 스피커·AirPlay 등 맥 쪽 출력 장치로 전달합니다. 자동 연결은 USB를 우선해 이중 수신을 피합니다. 한 번 연결한 TX-6의 Bluetooth 식별자를 기억하고 제한된 검색·연결을 재시도합니다. CoreMIDI 등록이 지연되면 표준 BLE MIDI 특성을 CoreBluetooth로 직접 구독하는 복구 경로를 사용하며, 정상 CoreMIDI 소스가 나타나면 직접 수신을 중단합니다. 기기가 꺼졌거나 BLE 연결을 허용하지 않는 상태에서는 앱이 기기 설정을 원격 변경할 수 없습니다. 최초 무선 연결은 Bluetooth 연결 화면에서 허용해야 합니다.

앱별 EQ는 맥에서 처리합니다. 따라서 현재 구현에는 TX-6의 12 IN 설정이 필요하지 않습니다. `12 IN`은 나중에 서로 다른 앱을 TX-6의 실제 USB 채널로 분리하는 별도 라우팅을 사용할 때의 설정이며, 현재 앱은 선택한 출력의 스테레오 페어로 믹스합니다.

## 하드웨어 조작

| 컨트롤 | 동작 |
|---|---|
| 트랙 1 페이더 | 시스템 효과음 음량 |
| 트랙 2~6 페이더 | 자동 배치된 앱 또는 연결한 탭 음량 |
| 위 노브 / 파랑 | HIGH EQ |
| 중간 노브 / 주황 | MID EQ |
| 아래 노브 / 흰색 | LOW EQ |
| 트랙 1~6 버튼 | 해당 프로그램 음소거 토글 |
| SELECT 회전 | 전체 음량 |
| FX1 | 전체 음소거 해제 |
| FX2 | 전체 음소거 |

페이더·노브는 기본으로 즉시 반영됩니다. 설정의 픽업을 켜면 하드웨어 위치가 현재 맥 값에 도달하거나 통과한 뒤 제어를 시작합니다.

EQ는 LOW 120Hz shelf, MID 1kHz peaking, HIGH 8kHz shelf, 각 ±18dB입니다. TX-6 내부 DSP를 복제한 것이 아니라 맥에서 동작하는 독립된 3밴드 EQ입니다. 프로그램·마스터 음량에는 짧은 보간을 적용하고, EQ 부스트 시 출력 피크를 제한합니다.

공식 MIDI 채널 1의 CC1~6(페이더), CC7~12(HIGH), CC13~18(MID), CC19~24(LOW), CC25~30(트랙 버튼), CC31(SELECT), CC33(FX1), CC34(FX2)을 사용합니다. 사용자 설정으로 노브에 별도 CC를 할당했다면 기본 CTRL OUT 번호와 다를 수 있습니다.

## Chrome 탭별 제어

`install.command`는 맥 앱과 이 사용자용 Native Messaging 호스트를 설치합니다. 기본 위치는 `/Applications/TX6Mac.app`이며, 인수로 설치 디렉터리를 지정할 수 있습니다. 설치된 앱의 `Contents/Resources/BrowserExtension` 폴더를 사용하면 소스 폴더를 옮겨도 확장을 계속 사용할 수 있습니다. Chrome에서 `chrome://extensions`를 직접 열어 개발자 모드를 켜고 `BrowserExtension` 폴더를 압축해제된 확장으로 로드합니다. 확장 ID는 `pphajfbmohpnobkajebnaaoildfenkcf`입니다. 이미 로드한 확장을 소스 업데이트했다면 해당 확장의 새로고침을 한 번 누릅니다.

소리 나는 탭의 제목·도메인은 자동 감지되어 앱 채널로 표시됩니다. 탭별 음소거는 클릭 없이 사용할 수 있습니다. 정확한 탭별 음량·EQ를 사용하려면 그 탭에서 확장 아이콘 또는 `Command+Shift+6`을 한 번 사용합니다. Chrome의 tabCapture 권한 구조 때문에 최초 연결 동작은 필요합니다. 연결하지 않은 탭에는 음량·EQ 비활성과 연결 안내를 표시합니다. 연결된 탭은 페이지 이동 시에도 유지되며 탭을 닫거나 다시 액션을 실행하면 해제됩니다.

배지 `DET`는 자동 감지, `CAP`는 캡처 중이지만 맥 믹서 대기, `ON`은 활성 맥 믹서와 연결된 상태입니다. 처리 오디오는 브라우저 메모리에만 있고, 제목·도메인·레벨·제어 값은 이 맥의 로컬 프로세스 사이에만 전달됩니다. 외부 서버·녹음 파일은 사용하지 않습니다. 브리지는 동일 로그인 세션의 로컬 알림을 사용하며, 적대적인 같은 사용자 프로세스에 대한 별도 보안 경계는 아닙니다.

믹서를 중지하거나 연결이 끊기면 확장의 음량·EQ를 중립으로 되돌리고, 확장이 변경한 미캡처 탭의 음소거만 원래대로 복구합니다. 사용자 또는 다른 확장이 설정한 음소거는 보존합니다.

## 기기 메뉴와 숫자 표시

앱은 MIDI의 SELECT 상대 회전 CC31을 전체 음량으로 해석합니다. 이 CC는 기기 메뉴에서도 발생하므로 SHIFT·SELECT·AUX·CUE와 메뉴 조합을 추적하여 메뉴 안에서는 맥 제어를 일시정지합니다. 기기에서 SHIFT를 단독으로 눌러 홈으로 복귀하면 다시 제어합니다. 시작·재연결 때는 기기 화면을 알 수 없어 홈 확인부터 요구하며, 앱의 재개 버튼으로도 명시적으로 재개할 수 있습니다.

플러그 삽입 등 MIDI로 공지되지 않는 기기 화면 전환은 자동 감지할 수 없습니다. 필요하면 제어를 일시정지하고 메뉴 조작 후 홈 확인·재개를 사용합니다.

TX-6 내부 메인 음량과 맥 소프트웨어 음량은 별도 값입니다. 자동 절대값 조회·상시 양방향 동기화는 지원된다고 확인하지 못했습니다. SETUP의 현재 기기 숫자 입력은 맥 값을 수동으로 맞추는 보정이며, 이후 앱에서만 값을 바꾸면 기기 숫자가 자동으로 바뀌지는 않습니다. 기기 내부 음량까지 자동으로 낮추면 TX-6 출력에서 이중 감쇠될 수 있으므로 앱은 메인 음량을 기기로 역송신하지 않습니다.

공식 업데이트 도구의 실제 TX-6 OS 1.3.3+1 응답을 수동 관찰했을 때 공통 설정 조회 명령 6은 status 2(not-found)를 반환했습니다. 공개 MIDI 표와 조사한 업데이트 프로토콜에서 임의 LCD 화면 쓰기나 버튼 LED 전용 제어 명령은 확인하지 못했습니다. 이 앱은 기기 펌웨어를 수정하지 않습니다. SYNTH·DJ 모드는 OFF, SOLO는 MUTE, CTRL은 OUT을 권장합니다. 실제 기기의 버튼 표시등과 맥의 음소거 상태가 동기화된다고 보장하지 않습니다.

## 빌드 및 진단

Xcode Command Line Tools와 macOS 26 이상이 필요합니다. 외부 패키지나 가상 오디오 드라이버를 설치하지 않습니다.

```sh
./build.sh
"$HOME/Library/Developer/TX6Mac/Build/TX6Mac.app/Contents/MacOS/TX6Mac" --self-check
"$HOME/Library/Developer/TX6Mac/Build/TX6Mac.app/Contents/MacOS/TX6Mac" --diagnose
./install.command
# /Applications에 쓸 수 없는 환경에서는 사용자 Applications 디렉터리 사용
./install.command "$HOME/Applications"
```

기본 빌드 위치는 `~/Library/Developer/TX6Mac/Build/TX6Mac.app`입니다. 이 맥의 Documents 동기화 FileProvider는 `.nosync` 아래에도 앱의 Finder 메타데이터를 자동 재생성해 코드 서명 검증을 깨뜨리는 것이 확인되어, 기본 빌드는 Library 아래에 둡니다. 명시적 빌드 대상도 `/Applications` 등 동기화하지 않는 디렉터리를 사용하세요. 빌드는 임시 앱을 완성한 뒤 서명·리소스·셀프체크를 검증하고 최종 위치로 옮깁니다. 기존 위치가 현재 사용자 소유의 TX6Mac 번들이 아니거나 심볼릭 링크이면 덮어쓰지 않습니다. 업데이트할 앱이 실행 중이면 먼저 앱 메뉴에서 종료해야 합니다. 설치는 다른 앱·브라우저 설정을 삭제하지 않으며, 이 앱의 Native Messaging 매니페스트만 원자적으로 갱신합니다. 매니페스트 권한은 현재 사용자 전용 `0600`입니다.

기본 앱 버전은 `0.3.0` / 빌드 `3`입니다. `APP_VERSION`과 `BUILD_NUMBER` 환경 변수로 재정의합니다. 로컬 기본 서명은 ad-hoc이며, 서명 인증서를 명시할 때는 다음처럼 실행합니다.

```sh
security find-identity -v -p codesigning
```

출력된 인증서의 정확한 이름 또는 SHA-1을 `SIGN_IDENTITY` 환경 변수로 지정해 `./build.sh`를 실행합니다. 명시적 인증서 서명에는 Hardened Runtime과 보안 타임스탬프를 적용합니다. 빌드는 공증이나 외부 업로드를 실행하지 않습니다. Apple Development 인증서·ad-hoc 서명은 일반 외부 배포 준비 완료를 의미하지 않습니다. 다른 맥에 인터넷으로 배포하려면 Developer ID Application 인증서, 공증, Gatekeeper 및 깨끗한 맥에서의 설치·권한·오디오 검증을 별도로 완료해야 합니다. 권한을 얻기 위해 격리 속성을 일괄 제거하거나 Gatekeeper를 끌 필요는 없습니다.

`Sources/Audio.m`은 Core Audio 프로세스 탭·EQ·믹서·출력, `Sources/MIDI.m`은 USB/BLE Core MIDI 수신, `Sources/App.m`은 AppKit 창·메뉴바·설정 저장, `Sources/BrowserBridge.m`과 `Sources/BrowserHost.m`은 Chrome Native Messaging 브리지, `Sources/Localization.m`과 `Resources/{en,ko,ja}.lproj`는 앱 문구와 시스템 권한 설명, `Sources/Icon.swift`는 앱 아이콘을 담당합니다. 빌드에는 세 언어의 Localizable·InfoPlist 리소스와 Chrome 확장이 포함됩니다.

내장 셀프체크는 실제 기기 청취 검사와 별개입니다. 출력 장치별 지연, Bluetooth 페어링, 권한과 실제 음악 재생은 실행 환경에서 확인해야 합니다. 보호된 콘텐츠나 개별 앱의 오디오 정책에 따라 캡처가 제한될 수 있습니다.

## 디자인과 자료

TX-6의 6채널 세로 구조, HIGH 파랑·MID 주황·LOW 흰색 대응과 ±18dB 표기를 기본으로 삼고, EP-133의 인쇄 라벨·키캡, OP-1의 밝은 본체와 디스플레이 대비, OP-Z의 색과 상태 대응을 참고했습니다. 색상값은 공식 브랜드 토큰이 아니라 제품 사진을 바탕으로 조정한 앱용 값입니다. 로고나 전용 웹폰트는 복제하지 않았습니다. teenage engineering의 공식 앱이 아닙니다.

- [TX-6 공식 매뉴얼](https://teenage.engineering/guides/tx-6)
- [TX-6 제품](https://teenage.engineering/products/tx-6)
- [EP-133 제품](https://teenage.engineering/products/ep-133)
- [EP-133 조작 매뉴얼](https://teenage.engineering/guides/ep-133/buttons-and-combos)
- [OP-1 제품](https://teenage.engineering/products/op-1)
- [OP-Z 인터페이스](https://teenage.engineering/guides/op-z/interface-overview)
- [OP-Z 믹서](https://teenage.engineering/guides/op-z/mixer)
- [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple HIG: Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy)
- [Apple Bluetooth 권한 설명](https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription)
- [Apple Developer ID 및 Gatekeeper 배포](https://developer.apple.com/developer-id/)
- [원래 BLE MIDI 참조](https://github.com/darnfish/use-tx-6)
- [MIDI 이벤트 해석 참조](https://github.com/darnfish/tx-6-midi-events)
- [확장 TX-6 참조 프로젝트](https://github.com/jakeisnt/tx-6)

장치 조사에 참조한 Git 저장소 코드는 앱에 복사하지 않았으며, 공개 MIDI 매핑과 Apple SDK로 별도 구현했습니다. 공식 업데이트 도구는 펌웨어 작업용이며, 앱 기능에 펌웨어 플래시는 필요하지 않습니다.
