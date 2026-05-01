# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Visão geral do projeto

OTClientV8 (OTCv8) é um cliente alternativo de código aberto para Tibia. É uma engine em C++17 que inicializa uma aplicação totalmente roteirizada em Lua. Praticamente toda a lógica de gameplay, UI e tratamento de protocolo vive em Lua, dentro de `modules/`; o lado C++ em `src/` fornece os serviços do framework (gráficos, rede, som, gerenciamento de recursos, engine Lua) e uma camada `client/` que expõe primitivas específicas de Tibia (criaturas, itens, mapa, parsing de protocolo) para Lua.

`main.cpp` inicializa `g_resources`, `g_app`, `g_client`, `g_http` e então executa `init.lua` — esse é o verdadeiro ponto de entrada da aplicação.

## Build e execução

### Windows (principal)
- Visual Studio 2019 + vcpkg fixado no commit `3b3bd424827a1f7f4813216f6b32b6c61e386b2e`.
- Instalar as dependências em x86-windows-static (lista completa no `README.md`).
- Abrir `vc16/otclient.sln`. O CI compila duas configurações: `DirectX` (gera `otclient_dx.exe`) e `OpenGL` (gera `otclient_gl.exe`).

### Linux / macOS
```
mkdir build && cd build && cmake .. && make -j8
```
Em Linux/macOS o vcpkg é fixado no commit `761c81d43335a5d5ccc2ec8ad90bd7e2cbba734e`. Requer gcc >= 9, boost >= 1.67, libzip-dev e physfs >= 3.

### Android
`android/` contém o projeto do Visual Studio. Requer `android-ndk-r21b` em `C:\android` e as libs de `android_libs.7z`. O script `create_android_assets.ps1` empacota `data/`, `modules/`, `layouts/`, `mods/` e `init.lua` em um `data.zip` colocado em `android/otclientv8/assets`.

### Opções do CMake (raiz)
`FRAMEWORK_SOUND` (padrão OFF), `FRAMEWORK_GRAPHICS` (ON), `FRAMEWORK_XML` (ON), `FRAMEWORK_NET` (ON). Use `-DVERSION=<n>` para gravar um número de build.

## Execução e testes

- `otclient_debug.exe` (ou o equivalente compilado) — execução normal.
- `otclient_debug.exe --test` — executa `test.lua`, que faz `dofiles("tests")` e roda o harness `Test.*` definido em `modules/corelib/test.lua`. Requer os arquivos de `tests.7z` descompactados no diretório de trabalho. Retorna exit code diferente de zero em caso de falha; gera screenshots e `otclientv8.log`.
- `otclient_debug.exe --mobile` — força o layout mobile, útil para testar a UI mobile.
- `--encrypt` (apenas com `WITH_ENCRYPTION` definido) — criptografa o archive de dados e encerra.

Não existe um runner de testes unitários no sentido tradicional; os testes são scripts Lua em `tests/` que dirigem o cliente vivo e verificam resultados via callbacks `test()`/`fail()`. Para rodar um único teste temporariamente, edite `test.lua` para fazer `dofile` apenas do arquivo desejado em vez de `dofiles("tests")`.

## Arquitetura

### Sequência de boot Lua (`init.lua`)
Os módulos são descobertos automaticamente em `modules/` e carregados em faixas de prioridade definidas no `.otmod` de cada módulo:
- `0–99` — bibliotecas (`corelib`, `gamelib`).
- `100–499` — módulos do cliente (`client`, `client_entergame`, `client_options`, …).
- `500–999` — módulos de gameplay (`game_interface`, `game_inventory`, `game_battle`, …).
- `1000–9999` — `mods/` (adições de terceiros; veja `mods/game_healthbars` como exemplo).

`corelib`, `gamelib`, `client` e `game_interface` recebem `ensureModuleLoaded` explicitamente após sua faixa. `crash_reporter` e `updater` são carregados condicionalmente conforme as URLs em `Services` no `init.lua`. Quando o updater roda, ele intercepta e replanaja `loadModules` após aplicar patches.

### Layout de `modules/`
- `corelib/` — extensões da biblioteca padrão Lua, settings, helpers de rede, classes-base de UI (`modules/corelib/ui`), JSON, HTTP, helpers de struct/binário e o framework de testes.
- `gamelib/` — helpers Lua específicos do jogo, compartilhados entre os módulos `game_*`: bindings de protocolo, wrappers de creature/player/thing, market, matemática de posição.
- `client_*` — UI fora do jogo (login, opções, locales, profiles, terminal, top menu, shell mobile).
- `game_*` — cada painel/sistema da UI dentro do jogo é um módulo próprio com arquivos `.otmod`, `.lua` e `.otui`. Os módulos conectam/desconectam de eventos de `g_game` em `init()`/`terminate()`.

### Layout de `src/`
- `src/framework/` — engine, agnóstica de plataforma sempre que possível:
  - `core/` — `application`, `eventdispatcher`, `module`/`modulemanager`, `resourcemanager` (VFS baseado em PhysFS sobre `data/`, `modules/`, `layouts/`, `mods/`, com suporte a archive embutido no executável), `logger`, `clock`.
  - `luaengine/` — binding LuaJIT (`luainterface`, `luaobject`, `luabinder`, `luavaluecasts`); toda classe C++ exposta a Lua passa por aqui.
  - `graphics/`, `sound/`, `net/`, `http/`, `input/`, `platform/`, `proxy/`, `otml/` (linguagem de configuração), `xml/`, `stdext/`, `util/`, `ui/` (UI declarativa carregada de arquivos `.otui`).
- `src/client/` — camada de domínio Tibia: `game`, `map`/`mapview`, `creature`/`localplayer`, `item`/`itemtype`/`thingtypemanager`, `protocolgame*` (parse/send), `spritemanager`, `minimap`, além de widgets de UI (`uimap`, `uiminimap`, `uicreature`, `uiitem`, …). `luafunctions_client.cpp` e `luavaluecasts_client.*` são onde os símbolos C++ se tornam visíveis em Lua.
- `src/android/` — glue JNI/AAsset usado quando o alvo é Android (entry point em `android_main` no `main.cpp`).

### Recursos e layouts
`g_resources` monta `data/`, `modules/`, `layouts/` e `mods/` em um único filesystem virtual. O layout ativo (definido no `init.lua` via `DEFAULT_LAYOUT` ou pelo setting `layout` persistido; forçado a `mobile` no Android) sobrepõe arquivos: qualquer coisa em `layouts/<nome>/...` sombreia o mesmo path em `data/...`. **Não** crie um layout chamado `default` — nome reservado. Layouts disponíveis: `retro` (padrão), `mobile`.

### `mods/` versus `modules/`
`mods/` é para add-ons opcionais/comunidade carregados por último (prioridade 1000+). `modules/` é para funcionalidade de primeira parte.

## Convenções do projeto

- **Features customizadas devem ser opt-in.** Toda feature nova de gameplay precisa estar protegida por `g_game.enableFeature(...)`, e a flag precisa ser declarada em `modules/gamelib/const.lua`. Pull requests adicionando features sempre-ligadas são rejeitados pela política de contribuição do projeto. O conjunto padrão, dependente de versão, fica em `modules/game_features/features.lua`.
- **`init.lua` é configuração voltada ao usuário**, não código de engine. `APP_NAME`, `APP_VERSION`, URLs de `Services` e a lista `Servers` foram pensadas para serem editadas por deployment. Não engesse forks em outros arquivos quando o `init.lua` já expõe a alavanca.
- **Reload de módulos**: `corelib` é `reloadable: false`; a maioria dos módulos de jogo é reloadable. `init()`/`terminate()` precisam ser simétricos para que o live reload funcione.
- **Código de protocolo**: o parse/send do protocolo Tibia no lado cliente está em `src/client/protocolgame{parse,send}.cpp`; opcodes em `protocolcodes.h`. Helpers Lua de protocolo (extended opcodes, login) ficam em `modules/gamelib/protocol*.lua`.
- **Arquivos de UI**: `.otui` é a linguagem declarativa de UI consumida por `framework/ui`; `.otmod` é o manifesto do módulo com hooks `@onLoad`/`@onUnload`; `.otml` é configuração OTML.

## CI

`.github/workflows/ci-cd.yml` compila Windows (DX + GL), Android, macOS e Linux em pushes para `main`/`master`, depois roda `--test` de forma headless no Windows e republica os artefatos no repositório público `OTCv8/otclientv8`. Inclua `[skip release]` na mensagem do commit para pular o pipeline de release. `pr-test.yml` roda em PRs; `build-on-request.yml` é um build acionado manualmente.
