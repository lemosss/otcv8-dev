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

### Build local em Windows com VS 2022 BuildTools (bit-rot do vcpkg pinado)

A receita acima foi escrita pra VS 2019 + vcpkg de mar/2022. Em ~2026, várias dependências externas pinadas por hash sumiram e o build local quebra em pontos previsíveis. Foi possível buildar com VS 2022 BuildTools 17.14 (sem VS 2019 instalado) aplicando estes patches no `C:\vcpkg-otcv8` (clone separado do `microsoft/vcpkg` no commit pinado):

1. **Toolset v142**: o componente genérico `Microsoft.VisualStudio.Component.VC.v142` foi removido do canal VS 2022. Use o "fixed version" `Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64` (instala MSVC 14.29.30133 = v142). Sem ele, o vcpkg-tool de mar/2022 rejeita o VS install com "Unable to find a valid Visual Studio instance" porque ele só reconhece toolsets `14.1x/14.2x/14.3x` — MSVC 14.4x (v143 atual) cai no branch "unknown toolset minor version".

2. **vcpkg.exe correto**: `vcpkg-otcv8` precisa do `vcpkg.exe` que casa com o port tree pinado (`2022-03-09`). Se já existe um `vcpkg.exe` mais novo no diretório, ele falha com `scripts/vcpkg-tools.json: error: calling read_contents failed with 2`. Solução: apagar o exe e rodar `bootstrap-vcpkg.bat` — baixa o `vcpkg.exe` certo de `microsoft/vcpkg-tool/releases/download/2022-03-09/`.

3. **7-Zip 21.07 URL morta**: `vcpkgTools.xml` aponta pra `https://www.7-zip.org/a/7z2107-extra.7z` (404). Baixar do mirror oficial em `https://github.com/ip7z/7zip/releases/download/21.07/7z2107-extra.7z` (SHA-512 confere com o pinado `648d894940bcc29951...`) e colocar em `C:\vcpkg-otcv8\downloads\7z2107-extra.7z`.

4. **MSYS2 pkg-config + libwinpthread URLs rotacionadas**: `repo.msys2.org` só mantém versão atual. As pinadas (`mingw-w64-i686-pkg-config-0.29.2-3` e `libwinpthread-git-9.0.0.6373.5be8fcd83-1`) foram removidas dos mirrors e a Wayback não tem snapshot. Editar `scripts/cmake/vcpkg_find_acquire_program.cmake` pra usar versões atuais (na época da fixa: `pkg-config-0.29.2-6` e `libwinpthread-git-12.0.0.r264.g5c63f0a96-1`) — atualizar URL **e** SHA-512 nas duas chamadas dentro do bloco `vcpkg_acquire_msys(PKGCONFIG_ROOT ...)`. Isso destrava `bzip2`, `liblzma`, `zstd`, `libogg`, `libvorbis`, `libzip`, `glew`, `physfs`, `openal-soft`, `opengl`, `zlib` (todos chamam `vcpkg_fixup_pkgconfig`).

5. **Gerador CMake `Visual Studio 16 2019`**: alguns ports (`openal-soft`, `physfs`) usam `vcpkg_configure_cmake` que mapeia `VCPKG_PLATFORM_TOOLSET=v142` → `-G "Visual Studio 16 2019"`. CMake exige uma instalação real de VS 2019 pra esse gerador — não basta ter o toolset v142 dentro do VS 2022. Editar `scripts/cmake/vcpkg_configure_cmake.cmake`, no branch `v142`, trocar pra `Visual Studio 17 2022` e definir `set(generator_toolset "v142")`; depois adicionar logo após o `-A${generator_arch}`:
   ```cmake
   if(DEFINED generator_toolset AND NOT "${generator_toolset}" STREQUAL "")
       vcpkg_list(APPEND arg_OPTIONS "-T${generator_toolset}")
   endif()
   ```

Com tudo isso aplicado, `vcpkg install --triplet x86-windows-static --recurse <lista do build-on-request.yml>` completa, e `MSBuild vc16/otclient.sln /p:Configuration=OpenGL /p:Platform=Win32` (e `=DirectX`) sai limpo gerando `otclient_gl.exe` (~9.6 MB) e `otclient_dx.exe` (~9.4 MB) na raiz.

Os patches são todos contidos em `C:\vcpkg-otcv8` — nenhum arquivo do otcv8-dev é modificado. Se reproduzir num CI moderno, vale automatizar via script (substituições `sed`/`Edit` em cima do clone fresco do vcpkg, mais o pre-stage do `7z2107-extra.7z` em `downloads/`).

#### Estado atual da máquina e como rodar a build

Patches do vcpkg, MSVC 14.29 (v142) e dependências em `x86-windows-static` já estão tudo instalado na máquina (em 2026-04-30). Não precisa repetir os passos acima — apenas rebuildar.

**Rebuildar do zero (quando alterar código C++):**

```powershell
# Rodar de qualquer terminal — não precisa Developer Command Prompt
$msbuild = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
cd "C:\Users\Lemos\Desktop\Realera OT\otcv8-dev\vc16"

# OpenGL (gera otclient_gl.exe na raiz do projeto)
& $msbuild /m /p:Configuration=OpenGL /p:Platform=Win32 /p:BUILD_REVISION=1 otclient.sln

# DirectX (gera otclient_dx.exe na raiz do projeto)
& $msbuild /m /p:Configuration=DirectX /p:Platform=Win32 /p:BUILD_REVISION=1 otclient.sln
```

`/m` paraleliza por core. Build limpo demora ~2-3 min cada config. Build incremental (após editar 1-2 arquivos) é segundos.

**Rodar o cliente:** o `.exe` precisa de `data/`, `modules/`, `layouts/`, `mods/` e `init.lua` ao lado — todos já presentes na raiz do `otcv8-dev/`. É só:

```powershell
cd "C:\Users\Lemos\Desktop\Realera OT\otcv8-dev"
.\otclient_gl.exe        # ou .\otclient_dx.exe
```

Flags úteis (já documentadas em "Execução e testes" abaixo): `--test` (harness de testes), `--mobile` (força layout mobile).

**Reinstalar uma dep do vcpkg** (se um port for atualizado):

```powershell
cd C:\vcpkg-otcv8
.\vcpkg.exe install --triplet x86-windows-static --recurse <pacote>
```

**Limpar build artefacts** (caso uma compilação fique inconsistente): apagar `vc16\Win32\` (objs/PDBs) e os `.exe` da raiz; o linker recria.

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

## PlayerShop label bubble (source patch em `src/client/creature.cpp`)

A loja de jogador (módulo `modules/game_playershop/`) usa `Creature:setTitle(text, font, color)` para desenhar o nome da loja em cima do char vendedor. Por padrão o engine só renderiza o texto do `m_titleCache` cru -- ficaria flutuando solto sobre o nome. O patch em `Creature::drawInformation` (perto da linha 270, dentro do `if (m_titleCache.hasText())`) embrulha o texto em uma "placa" estilizada:

```cpp
// Margem vertical entre name e title (sem isso, balao encostava no nome).
textCenter.y -= 6;
textRect.setSize(titleSize);
textRect.moveBottomCenter(textCenter);

// Padding lateral mais largo (4px) que vertical (2px) pro texto respirar.
Rect bubbleRect(textRect.left() - 4, textRect.top() - 2,
                textRect.width() + 8, textRect.height() + 4);

// Background cinza escuro semi-transparente (alpha 160 ~ 63%): tile do
// mapa atras vaza um pouco, dando aparencia de placa leve.
g_drawQueue->addFilledRect(bubbleRect, Color(50, 50, 50, 160));

// Border dourado fixo (#FFD700), independente do m_titleColor.
Color gold(255, 215, 0);
g_drawQueue->addBoundingRect(bubbleRect, 1, gold);

// Quatro "marcadores" dourados de 3x3 px nos cantos, estilo placa
// fixada (referência de imagem do user). Os pontos sangram metade pra
// fora do rect pra dar o efeito de fixador.
int dotSize = 3, half = dotSize / 2;
int l = bubbleRect.left() - half, r = bubbleRect.right() - half;
int t = bubbleRect.top() - half,  b = bubbleRect.bottom() - half;
g_drawQueue->addFilledRect(Rect(l, t, dotSize, dotSize), gold);
g_drawQueue->addFilledRect(Rect(r, t, dotSize, dotSize), gold);
g_drawQueue->addFilledRect(Rect(l, b, dotSize, dotSize), gold);
g_drawQueue->addFilledRect(Rect(r, b, dotSize, dotSize), gold);

m_titleCache.draw(textRect, m_titleColor);
```

A textura/cor do texto continua vindo do `setTitle` lá no Lua: `playershop.lua` chama `creature:setTitle(text, 'verdana-9px', '#ffffff')` -- `verdana-9px` (sem bold) e branco. Trocar fonte/cor é hot-reload (Ctrl+R no client, sem rebuild).

`setTitle` é exposto pra Lua em `src/client/luafunctions_client.cpp:552-554` -- já existia desde a release prebuilt 3.2 rev 4 por sorte. O patch acima é o único pedaço de C++ que a feature do balão exige; tudo o resto (carregar fonte, decidir quando setar/limpar o título, sincronizar com o servidor) vive em Lua.

Outras features Lua-only do PlayerShop que valem deixar registradas:

- **`SHOP_ICON = 7`** em `Skulls_t` (server-side `src/const.h`) + `ShopIcon = 7` em `modules/gamelib/creature.lua` mapeando para `/modules/game_playershop/icons/shop_icon`. O server retorna esse skull em `Player::getSkullClient` quando o storage `88810 == 1`, e o cliente entrega o ícone via packet `AddCreature` -- mesmo caminho do skull de PK, sem opcode custom. Patch correspondente fica do lado server (Realera TFS 1.5).
- **Walking lock** em `modules/game_walking/walking.lua`: `walk()` e `turn()` early-return se `modules.game_playershop.iAmSelling`. Junto com o walking lock do servidor, isso garante que o vendedor fique ancorado.
- **Right-click no chão durante venda**: NÃO modificar `processMouseAction` em `gameinterface.lua` para forçar menu -- isso quebra o classic control (que usa right-click para look/use). O lock só precisa estar em `walking.lua` mesmo; o server também rejeita movimento via `setMovementBlocked(true)` no cylinder do char vendedor.
- **Right-click no próprio char abre owner-view** (com a loja em modo gerenciar) via menu hook em `playershop.lua`. Esse caminho usa o `gi2.addMenuHook` que é executado pelo `createThingMenu` -- não precisa interceptação manual.

## PlayerShop — buyer-view layout v2 + gold counter + rune drag

Sessão de retrabalho da janela de comprador (Day-9 do CLAUDE.md do server `Realera TFS 1.5/`). Resumo do que vive nesse repo:

### `modules/game_playershop/playershop.otui` — `ShopViewWindow` reescrito
Layout antigo era uma lista vertical de `ShopBuyRow` (slot + nome + preço + qty + Buy por linha). Novo layout = grid de sprites + painel inferior único:

- **Top**: search bar (`searchEdit` + `searchClearBtn`) ancorada só na METADE direita da janela (`anchors.left: parent.horizontalCenter`), com `searchLbl` flutuando à esquerda do edit.
- **Middle**: `viewItems` (ScrollablePanel com `layout: type=grid, cell-size: 38 38`) populado por `ShopBuyCell` (UIWidget de 36x36, `Item` interno default — slot bg natural). Hover/selected = borda dourada via `$hover`/`$on`.
- **Bottom info panel** (UIWidget 110px alto, dividido em 3 colunas): `selName` + `priceLbl` + `amountScroll` (HorizontalScrollBar) + `amountLbl` + `weightLbl` à esquerda; `previewSlot` + `buyBtn` no meio; `descPanel` (textura `panel_flat`, 90px alto) à direita.
- **Footer**: `goldBox` (texturizado `panel_flat`, 150x20, contém `goldIcon` UIItem com `item-id: 3031` = client.dat gold coin) à esquerda + `closeBtn` à direita.

### `modules/game_playershop/shop_view.lua` — refatorado pro novo layout
- Cells em grid (`buildBuyerCell`) substituindo `buildItemRow`.
- Estado local: `viewEntries`, `selectedCell`, `selectedEntry`, `searchText`, `viewBalance`.
- `selectCell()` toggla `setOn` na cell selecionada.
- `applySearchFilter()` percorre cells e usa `setVisible(false)` por nome (case-insensitive substring). Filtro client-side puro -- server manda lista completa uma vez.
- `amountScroll.onValueChange` atualiza `amountLbl` E `previewItem:setItemCount(value)` (badge no preview reflete a qtd escolhida).
- Buy btn lê `selectedEntry.slot` + `amountScroll:getValue()` e dispara `OPCODE_SHOP_BUY`.
- Double-click numa cell = compra direta na qtd atual.

### Wire format SHOP_DATA — adicionados balance + weight
Server (`Realera TFS 1.5/data/scripts/playershop/02_core.lua`, função `PlayerShop_SendShopDataTo`) acrescenta:
1. **Logo após `isOwner u8`**: `u32 buyerBalance` -- soma de bank + cash (gold + plat×100 + crystal×10000), com walk recursivo do open backpack do comprador.
2. **Em cada item entry, antes de `name`**: `u32 weight` em unidades de 1/100 oz (= `ItemType:getWeight()`).

Client `shop_view_handle` parseia os dois e popula `viewBalance` (módulo-scope) + `entry.weight` por item. `refreshGoldLabel` mostra `viewBalance`; `refreshSelectionPanel` formata `weight / 100` com 2 casas.

### Rune drag stack (cont. do day-8)
A correção do drag de runa (que existia só no `otclientv80` prebuilt e não tinha sido portada pro source) finalmente caiu aqui:
- `modules/gamelib/ui/uiitem.lua` + `modules/game_interface/widgets/uigamemap.lua` -- routam item com id no range `3147-3203` (faixa de runa em Tibia.dat 8.0) via `moveStackableItem` em vez do path padrão.
- `modules/game_interface/gameinterface.lua` -- expõe `getEffectiveCount(item)` que retorna `getCountOrSubType()` para runas (a "contagem visível" no slot) e `getCount()` para o resto.
- `moveStackableItem.commit()` lê `itembox:getItemCountOrSubType()` em vez de `getItemCount()`. UIItem.getItemCount delega pra Item.getCount que retorna 1 pra dat-flagged-charge items mesmo após `setItemCount(N)` -- o byte cru `m_countOrSubType` é o que queremos.

### Bug do "verdana-11px" inexistente + comments OTUI
Dois typos que se compõem para "buyer não abre":
1. `playershop.lua` setando `'verdana-11px'` (sem sufixo) -- a font não existe; só `verdana-11px-antialised` / `-monochrome` / `-rounded`.
2. `playershop.otui` com linhas `-- comment` (Lua-style) que o OTML parser rejeita como "not a valid style declaration", quebrando todo o ShopViewWindow.

Lição: erro `failed to load UI from 'X.otui': '' is not a defined style` é sintoma de comment-line ou property-name typo. Não é bug Lua.

### Cleanup
- `modules/client/client.otmod` -- removido `client_mobile` que ficou pendurado de cleanups anteriores e gerava `Unable to find module 'client_mobile' required by 'client'` no boot.
- `modules/game_playershop/playershop.lua` -- `onGameEnd` agora derruba TODAS as janelas (createWindow / pickerWindow / viewWindow / qty prompt) via `closeCreateShop()` + `shop_view_close()`, evitando UI orfã atrás do login screen no Ctrl+Q.

### Open thread
- **CreateShopWindow** (lado vendedor) ainda usa o layout antigo de slot-list. A próxima sessão é redesenhar pra bater com a screenshot do Lemos's Shop: description-focused com Idle Shop / Edit Description / History.
