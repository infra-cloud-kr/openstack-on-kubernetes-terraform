# 문서 기여 가이드

이 저장소의 문서는 Sphinx 로 빌드하고 GitHub Pages 에 배포한다. 본문은
**Markdown(MyST)** 으로 작성한다. 한국어를 주력으로 하며, 다국어는 추후 Sphinx
i18n(gettext) 로 대응한다.

코드·인프라(terraform / osh) 기여는 저장소 루트의 `CONTRIBUTING.md`(프로젝트 기여 가이드)를 참고한다. 이 페이지는 문서 기여에만 해당한다.

## 문서 구조

- `doc/source/` — 문서 소스(Markdown). 주제별 디렉터리마다 `index.md` 가 하위
  페이지를 `toctree` 로 묶는다.
  - `getting-started/` — 설치, 설치 확인
  - `architecture/` — 아키텍처 개요, 설계 결정
  - `operations/` — OpenStack 사용, 트러블슈팅, 비용
- `doc/source/conf.py` — Sphinx 설정 (MyST 활성화).
- `doc/requirements.txt` — 빌드에 필요한 Python 패키지.
- `tox.ini` — `docs` 빌드 환경.

## 로컬 빌드

`tox` 만 있으면 된다.

```bash
pip install tox

tox -e docs     # 경고를 오류로 처리하며 HTML 빌드
```

빌드 결과는 `doc/build/html/index.html` 에 생성된다. 브라우저로 열어 확인한다.

`tox` 없이 직접 빌드하려면:

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r doc/requirements.txt
sphinx-build -W --keep-going -b html doc/source doc/build/html
```

## 작성 규칙

- 페이지는 일반 Markdown 으로 쓴다. 제목은 `#`, 표/코드블록/인용은 Markdown
  문법 그대로 사용한다.
- 디렉티브(`toctree`, `note`, `warning` 등)는 MyST 의 ```` ```{...} ```` 펜스로
  작성한다.
- 문서 간 링크는 대상 `.md` 파일의 상대 경로를 쓴다. 예: `[비용](../operations/cost.md)`.
- `sphinx-build -W` 로 빌드하므로 경고가 하나라도 있으면 실패한다. PR 전에
  `tox -e docs` 가 통과하는지 확인한다.
