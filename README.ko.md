# PhotoEmul

[spektrafilm](https://github.com/andreavolpato/spektrafilm) 위에 만든 macOS 필름 에뮬레이션 편집기입니다. 라이트룸 클래식과 왕복 편집을 지원합니다.

[English](README.md)

필름, 노출과 상반칙 불궤, 현상·보관, 확대기 광원과 필터, 인화지, 그레인, 할레이션, 렌즈까지 아날로그 과정 전체를 모델로 만들었습니다. 모든 조정은 GPU 렌더 실시간 미리보기로 바로 보입니다.

PhotoEmul은 spektrafilm, spektrafilm-ofx 작성자나 Adobe가 만들거나 지원하는 앱이 아닙니다.

- macOS 14 이상, Apple 실리콘·Intel
- 화면 언어: 영어, 한국어
- 사용 통계 수집 없음. AI 탭에서 AI 애드인을 켜지 않으면 네트워크에 접속하지 않음

## 기능

- spektrafilm의 필름·인화지(컬러 네거티브, 슬라이드, 영화용, 흑백, 인스턴트)와 파생 필름
- 촬영: 노출, 셔터 시간과 상반칙 불궤, 촬영 광원(주광, 텅스텐, 형광등, LED, 나트륨 등)
- 현상·보관: 온도, 시간, 현상액, 노화·습도, 현상 불균일, 브로마이드 드래그
- 암실: 확대기 광원과 Y/M/C 필터, 인화 노출, 테스트 스트립
- 그레인, 할레이션, 디퓨전, 먼지·스크래치, 렌즈 프로파일(lensfun)
- 히스토리 타임라인, 스냅샷, 프리셋, 나란히·분할 비교
- 라이트룸 클래식 플러그인: 사진을 보내 편집하고, 16비트 TIFF를 원본 위에 스택으로 돌려받음
- JPEG·16비트 TIFF 내보내기, 3D LUT 내보내기
- 선택 기능 AI 탭: 원하는 느낌을 말하면 모델이 제안한 편집을 단계별로 검토 (Claude API, OpenAI 호환 서버, 로컬 모델, 또는 내장 MCP 서버 `PhotoEmul --mcp`를 통한 Claude Code)

## 설치

### 내려받기

릴리스마다 파일이 두 개 있습니다. `PhotoEmul-<버전>.zip`(앱, Apple 실리콘·Intel)과 `PhotoEmul-Lightroom-<버전>.zip`(라이트룸 클래식 플러그인)입니다.

내려받은 빌드는 ad hoc 서명만 되어 있고 공증되지 않아서, 처음 열 때 macOS가 막습니다.

1. 압축을 풀고 PhotoEmul을 응용 프로그램 폴더로 옮겨 엽니다. "열리지 않음" 창이 뜨면 **완료**를 누릅니다(휴지통으로 이동 아님).
2. 시스템 설정 › 개인정보 보호 및 보안에서 아래로 내려 **그래도 열기**를 누릅니다.

또는 터미널에서: `xattr -dr com.apple.quarantine /Applications/PhotoEmul.app`

### 직접 빌드

Xcode 명령줄 도구(`xcode-select --install`)와 CMake가 필요합니다.

```sh
git clone --recursive https://github.com/yandyne/PhotoEmul.git
cd PhotoEmul
# 엔진(C++/Metal, spektrafilm-ofx)을 universal 정적 라이브러리로 한 번 설정
cmake -S build/ofx/SpektraFilm -B build/ofx/SpektraFilm/build-universal \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
app/build.sh                    # app/build/PhotoEmul.app (universal), 필요하면 엔진도 다시 빌드
ARCHS=arm64 app/build.sh        # Apple 실리콘만 (더 빠름)
app/build/PhotoEmul.app/Contents/MacOS/PhotoEmul --self-test   # 모두 통과하면 종료 코드 0
```

엔진은 git 서브모듈입니다. [yandyne/spektrafilm-ofx](https://github.com/yandyne/spektrafilm-ofx)의 `photoemul` 브랜치로, [chaert-s/spektrafilm-ofx](https://github.com/chaert-s/spektrafilm-ofx)에 PhotoEmul 변경을 더한 것입니다.

## 라이트룸 클래식

1. 플러그인 설치
   - 내려받은 경우: `PhotoEmul-Lightroom-<버전>.zip`을 풀고, 라이트룸 클래식 파일 › 플러그인 관리자 › 추가에서 `PhotoEmul.lrplugin`을 고릅니다. 앱은 `/Applications/PhotoEmul.app`에서 찾습니다.
   - 소스에서: `lightroom/install.sh`가 플러그인을 라이트룸 Modules 폴더에 복사하고 `app/build/PhotoEmul.app` 경로를 기록합니다(`--uninstall`로 제거).
2. 라이트룸을 재시작합니다. 앱 경로는 파일 › 플러그인 관리자 › PhotoEmul에서 바꿀 수 있습니다.
3. 사진을 고르고 파일 › 플러그인 추가 기능(또는 라이브러리 › 플러그인 추가 기능)에서:
   - **PhotoEmul에서 편집 (라이트룸 보정 적용)**: 현재 보정을 반영한 16비트 ProPhoto TIFF로 엽니다. 노출·화이트밸런스는 라이트룸에서, 필름 룩은 PhotoEmul에서 맞춥니다.
   - **PhotoEmul에서 편집 (원본 RAW)**: RAW 원본을 그대로 엽니다. 라이트룸 보정은 무시됩니다.
4. 여러 장이면 **모두 같은 편집**과 **한 장씩** 중에서 고릅니다.
5. 조정한 뒤 **Lightroom에 저장**을 누르면 `<원본이름>-photoemul.tif`가 원본 옆에 저장되고 원본 위에 스택됩니다.

저장하지 않고 닫으면 아무것도 추가되지 않습니다. 편집 값과 스냅샷은 사진마다 저장되어, 같은 사진을 다시 열면 이어서 편집합니다.

라이트룸(클라우드 버전)은 플러그인을 지원하지 않습니다. 로그: `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/PhotoEmul.log`

PhotoEmul은 단독으로도 쓸 수 있습니다. 파일을 열거나 창에 끌어다 놓고, 파일 › 내보내기로 저장합니다.

## 크리에이티브 프로파일 (보너스)

`tools/sf4lr`은 필름 룩을 LUT 내장 XMP 프로파일로 구워 라이트룸·Camera Raw 프로파일 브라우저에서 쓰게 합니다(그레인·할레이션·파라미터 없음). 미리 구운 파일은 `build/profiles/spektrafilm`에 있습니다. 직접 구우려면 Python 가상환경(`.venv`)에 spektrafilm이 설치되어 있어야 합니다.

```sh
cd tools && ../.venv/bin/python -m sf4lr.bake --out ../build/profiles/spektrafilm
cp -R ../build/profiles/spektrafilm/. ~/Library/Application\ Support/Adobe/CameraRaw/Settings/spektrafilm/
```

## 데이터 위치

- 설정: 앱 환경설정(`com.yandyne.PhotoEmul`)
- 프리셋, 세션, AI 애드인 소켓: `~/Library/Application Support/PhotoEmul/`
- AI API 키: macOS 키체인에만 저장
- 슬라이더 반응 기록: `~/Library/Logs/PhotoEmul/slider.log`

## 만든 방법

PhotoEmul은 한 사람이 AI 모델(Claude Code)과 함께 2026년 10월 21일부터 11월 22일까지, 작업한 날로 17일 동안 만들었습니다.
코드는 모델이 썼습니다. 작성자는 무엇을 만들지 정하고, 모든 변경을 직접 시험하고, 틀리면 다시 고치게 했습니다.

| | 작성자 | 모델 |
|---|---|---|
| 한 일 | 설계, 결정, 시험 | 코드, 테스트, 문서 |
| 양 | 메시지 526개, 사진·스크린샷 13장 | 응답 14,286개, 명령·파일 작업 7,456개 |
| 시간 | 약 36시간 | 약 46시간 |

작성자 메시지 526개의 종류:

| 종류 | 메시지 | 비율 |
|---|---|---|
| 질문·제안 요청 | 136 | 26% |
| 진행 관리 | 123 | 23% |
| 시험 결과·문제 보고 | 113 | 21% |
| 결정 | 82 | 16% |
| 요구·설계 | 72 | 14% |

| 모델 | 작업 시간 | 응답 |
|---|---|---|
| Claude Opus 5.5 | 35.2시간 | 11,923 |
| Claude Fable 5.1 | 10.1시간 | 2,218 |
| Claude Fable 5.2 | 0.5시간 | 145 |

<sub>2026년 11월 22일까지의 세션 기록에서 셌습니다. 모델 응답은 기록된 응답 이벤트 하나입니다(답 하나가 여러 개일 때가 많음). 시간은 추정치입니다. 모델은 이벤트 사이 간격이 5분 이하인 것만, 작성자는 모델의 마지막 이벤트에서 다음 메시지까지 30분 이하인 것만 더했습니다. 종류는 메시지를 하나씩 읽고 나눴으며, 둘 이상에 걸치는 것도 있습니다.</sub>

## 기여

개인 프로젝트입니다. 풀 리퀘스트는 받지 않고 이슈 기능은 꺼 두었습니다.
아래 라이선스에 따라 포크해서 직접 고쳐 쓰는 것은 환영합니다.

## 라이선스와 크레딧

PhotoEmul은 GNU General Public License v3.0 이상을 따르는 자유 소프트웨어입니다. [LICENSE](LICENSE)를 보세요.

- 필름 모델: [spektrafilm](https://github.com/andreavolpato/spektrafilm) (Andrea Volpato, GPL-3.0). 학술 작업에서는 저장소 / Zenodo DOI를 인용해 주세요.
- GPU 엔진: [spektrafilm-ofx](https://github.com/chaert-s/spektrafilm-ofx) (Aedan Diez, GPL-3.0)
- 필름·인화지·필터 프로파일: CC BY-SA 4.0 (spektrafilm). 파생 프로파일은 변경 내용을 적고 같은 라이선스로 공유합니다.
- 렌즈 프로파일: [lensfun](https://lensfun.github.io) 데이터베이스를 변환, CC BY-SA 3.0
- 먼지·스크래치 통계: [FilmDamageSimulator](https://github.com/daniela997/FilmDamageSimulator) (MIT)

라이선스 전문을 포함한 전체 목록은 [app/Credits.html](app/Credits.html)(앱 정보 창)에 있습니다.
"Lightroom"은 Adobe의 상표이며, 플러그인이 함께 동작하는 앱을 밝히기 위해서만 씁니다.
