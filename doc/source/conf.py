# -*- coding: utf-8 -*-
#
# Sphinx 빌드 설정 파일.
#
# 본문은 Markdown(MyST) 으로 작성한다. infra-cloud-kr/openstack-kubernetes 의
# 빌드/배포 관례(Sphinx + tox + GitHub Pages)는 그대로 따르되, 소스 포맷만
# reStructuredText 대신 Markdown 을 쓴다.
#
# 전체 설정 항목:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- 프로젝트 정보 -----------------------------------------------------------

project = 'OpenStack-on-Kubernetes 싱글노드 랩'
copyright = '2026, openstack-aws contributors'
author = 'openstack-aws contributors'

# -- 일반 설정 ---------------------------------------------------------------

extensions = [
    'myst_parser',            # Markdown(MyST) 소스 지원
    'sphinxcontrib.mermaid',  # 다이어그램(```mermaid 블록)
    'sphinx.ext.intersphinx',
    'sphinx.ext.todo',
]

# Markdown 을 기본 소스로 사용한다.
source_suffix = {
    '.md': 'markdown',
}

# ```mermaid 코드펜스를 mermaid 디렉티브로 처리한다. 이렇게 하면 동일한
# 블록이 GitHub(네이티브)와 Sphinx 양쪽에서 다이어그램으로 렌더된다.
myst_fence_as_directive = ['mermaid']

# 소스 파일의 기본 언어.
language = 'ko'

# 문서 최상위(root) 문서.
root_doc = 'index'

# 빌드에서 제외할 파일/디렉터리 패턴.
exclude_patterns = []

# todo 지시문을 출력에 표시.
todo_include_todos = True

# -- MyST 설정 ---------------------------------------------------------------
# 필요 시 확장 기능을 켠다. 기본만으로 충분하다.
myst_heading_anchors = 3

# -- HTML 출력 옵션 ----------------------------------------------------------

# furo: 계층형(collapsible) 사이드바 네비게이션을 제공하는 모던 테마.
# 섹션(시작하기/아키텍처/운영)이 클릭 가능한 랜딩 페이지로, 하위 문서가 그 아래
# 트리로 펼쳐진다.
html_theme = 'furo'

html_title = 'OpenStack-on-Kubernetes 싱글노드 랩'

# -- intersphinx 설정 --------------------------------------------------------
intersphinx_mapping = {}
intersphinx_timeout = 5
