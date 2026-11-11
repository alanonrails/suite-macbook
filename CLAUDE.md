# Suite MacBook

Apps nativos de macOS em Swift, cada um na sua pasta com seu `build.sh`:
- `alternador/` — Cmd+Tab por janela (e por aba do Safari), espaços virtuais, atalhos de janela.
- `launcher/` — lançador.
- `topbar/` — barra superior.

## Regras
- **Tudo acionado pelo teclado.** Não criar interação por clique ou mouse sem o usuário pedir.
- Não inventar features. Se uma ideia parecer útil, propor e perguntar antes de implementar.
- Comentários e textos da interface em português, curtos.

## Build
- Para checar erros, compilar com `swiftc` numa pasta temporária (não instala nada).
- Para instalar, o usuário roda `! <app>/build.sh`. A assinatura usa a identidade "Suite MacBook"
  do Chaveiro; rodada pelo Claude, ela falha com `errSecInternalComponent`.
