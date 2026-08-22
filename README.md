# lst-f

Explora e altera o filesystem no terminal. **A tela é o buffer do seu Vim ou
Neovim**: o `lst-f` abre o diretório como um buffer editável, você edita, salva,
e ele executa o que você escreveu.

```
lst-f v26.8.21  ~/Devel/lst-f  ·  Vim
──┬───────────┬───────────┬──────────────────┬──────────────────────────
T │ PERMS     │ SIZE      │ MODIFIED         │ NAME (editable)
──┼───────────┼───────────┼──────────────────┼──────────────────────────
d │ rwxr-xr-x │         - │ 2026-08-21 19:58 │  src/
- │ rw-r--r-- │      1.1K │ 2026-08-21 21:14 │  README.md
```

O cabeçalho ocupa as primeiras linhas e as entradas vêm logo abaixo. Pressionar **`F1` ou `?`** abre o popup de ajuda flutuante com os comandos e diretivas principais (`:cd`, `:find`, `:undo`, `:quit`), fechando com `q` ou `Esc`.

A primeira linha mostra permanentemente a versão, o diretório atual e se a sessão está usando **Vim** ou **Neovim**.

O ID à esquerda casa a linha com a entrada, então reordenar, rodar `:sort` ou
recolar linhas é inofensivo. Nada é gravado sem diff e confirmação, e as
remoções têm confirmação separada.

Sem plugin, sem gerenciador de pacotes: funciona com `vim` puro no servidor em
que você acabou de entrar por SSH.

## O que faz

| você escreve / digita               | acontece                                  |
| ----------------------------------- | ----------------------------------------- |
| muda o caminho de uma linha          | renomeia ou move (cria os pais que faltam) |
| apaga a linha                        | remove, via área de sessão                 |
| `q` no buffer                        | sai do `lst-f`                            |
| `ZZ`                                  | sai do `lst-f`                            |
| `F1` ou `?`                          | abre o helper popup de ajuda flutuante     |
| `Enter` sobre diretório               | entra nele                                 |
| `Enter` sobre arquivo de texto/código | abre-o no Vim/Neovim; `:q` volta à lista   |
| `Enter` sobre arquivo binário/mídia   | abre no app padrão via `xdg-open`          |
| `-`                                   | volta ao diretório anterior                |
| `\`                                   | abre uma árvore visual do diretório atual  |
| `Ctrl+P`                              | abre o buscador fuzzy (`fzf`) na árvore inteira |
| `Ctrl+S`                              | abre/fecha o painel dividido de destino    |
| `Tab`                                 | alterna o foco entre painel principal e split |
| `Y` ou `yy` no split                  | copia caminho do destino para colar (`p`)  |
| `:cd <dir>`                          | entra no diretório (`..` sobe)             |
| `:open <arquivo>`                    | abre o arquivo para edição no editor       |
| `:find [termo]`                      | busca fuzzy na árvore com o `fzf`          |
| `:undo`                              | desfaz a última operação da sessão         |
| `:quit`                              | sai (salvar sem mudanças também sai)       |
| `:cq` no editor                      | aborta sem aplicar nada                    |

Na árvore, use `j`/`k` ou as setas para navegar; `q`, `Esc`, `Enter` ou `\` a fecha. Para manter a abertura rápida em árvores grandes, ela mostra até 2.000 entradas e informa quando foi truncada.

Use `:w` para aplicar a edição no filesystem — mesmo sem alterações ele só atualiza a lista e mantém a sessão aberta. O `lst-f` fecha e reabre sua instância temporária do editor automaticamente após a confirmação; a sessão permanece no explorador, com um aviso no cabeçalho e o cursor na mesma linha aproximada. `q`, `:q`, `:quit` ou `ZZ` encerram a sessão de fato, inclusive quando há renomeações pendentes.

Em terminais estreitos, o nome editável pode ficar fora da área visível; use `zl` e `zh` para rolar horizontalmente.

O editor abre com o diretório atual como *cwd*, então `:e`, `gf` e completação
funcionam direto sobre os caminhos listados.

## `:find` — o fzf entra aqui

`:find relatorio` abre o `fzf` sobre a árvore inteira a partir do diretório
atual. Você filtra, marca com `Tab` o que interessa — espalhado por quantos
subdiretórios for — e o que foi marcado **vira o conteúdo do buffer**. Renomear
doze arquivos de seis diretórios diferentes é um `:find`, doze `Tab` e uma
edição.

No buscador: `Tab` marca, `Enter` aceita, `alt-p` abre e fecha o preview, `F1`
mostra a ajuda, `Esc` cancela.

## Requisitos

- Vim ou Neovim (prioridade para `vim`) ou `--editor <cmd>` — é a tela, não é opcional
- `fzf` 0.17 ou mais novo, só para o `:find`
- Zig 0.16.x para compilar

Os binários de runtime (`vim`, `nvim`, `fzf`) podem estar instalados no `$PATH` do sistema ou simplesmente colocados na mesma pasta do binário `lst-f` (modo bundle portátil, sem instalação e sem `sudo`).

Sem plugins, sem Node, Python, `fd`, `rg` ou Nerd Font.

## Instalação

```sh
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/lst-f ~/.local/bin/
```

Para rodar em distribuição estável (Debian, Ubuntu Server), compile contra uma
glibc antiga ou estaticamente:

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu.2.28
```

## Uso

```sh
lst-f                  # abre o diretório atual no editor
lst-f ~/projetos       # abre outro diretório
lst-f --find relatorio # começa direto no buscador
```

Opções: `--editor <cmd>`, `--max-depth <n>`, `--icons`, `--no-color`.

Para editar com uma configuração limpa: `lst-f --editor "vim -u NONE"`.

## Remoção

Apagar a linha remove a entrada, mas nada é apagado durante a aplicação: o que
sai vai por `rename()` para `.lst-f-<pid>/` no diretório-base, no mesmo modelo
de arquivo de swap do Vim. Enquanto a sessão estiver aberta, `:undo` traz tudo
de volta.

**Ao sair, a área é apagada e a remoção passa a ser definitiva.** O `lst-f` não
é uma lixeira: a garantia é sobre erro durante a operação e arrependimento
durante a sessão, não sobre recuperação amanhã.

Se a sessão morrer (crash, kill, queda de SSH), a área fica para trás e o
`lst-f` avisa no cabeçalho do buffer na abertura seguinte daquele diretório, sem
restaurar nem apagar sozinho.

## Nomes que não são UTF-8

O Vim não preserva bytes inválidos no round-trip. Entradas assim aparecem no
cabeçalho do buffer, com os bytes escapados, mas ficam fora da edição — o `ID`
estaria certo e o destino, corrompido.

## Desenvolvimento

```sh
zig build         # compila
zig build test    # roda a suíte
zig fmt .         # formata
```
