# lst-f

Explora e altera o filesystem no terminal, usando o `fzf` para navegar e o seu
Vim ou Neovim para editar operações em lote.

Lista um diretório por vez, com preview. Uma tecla alterna para busca fuzzy na
árvore inteira a partir dali, e a marcação múltipla atravessa subdiretórios: dá
para filtrar um termo, marcar doze resultados espalhados por seis diretórios e
renomear todos de uma vez, num fluxo só.

A edição acontece num buffer com um ID por linha:

```
0001  relatorio.pdf
0002  notas antigas.txt
0003  docs/rascunho.md
```

O ID casa a linha com a entrada, então reordenar, rodar `:sort` ou recolar
linhas é inofensivo. Apagar a linha remove a entrada. Nada é gravado sem diff e
confirmação, e as remoções têm confirmação separada.

## Requisitos

- `fzf` 0.17 ou mais novo (o `reload`, opcional, é detectado e usado quando há)
- Vim ou Neovim, apontado por `$VISUAL` ou `$EDITOR`
- Zig 0.16.x para compilar

Sem plugins, sem gerenciador de pacotes, sem Node, Python, `fd`, `rg` ou Nerd
Font.

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
lst-f            # lista o diretório atual
lst-f ~/projetos # lista outro diretório
```

| tecla    | ação                                                    |
| -------- | ------------------------------------------------------- |
| `Enter`  | abre o arquivo ou entra no diretório                    |
| `Tab`    | marca / desmarca                                        |
| `ctrl-r` | alterna entre listar o diretório e buscar na árvore     |
| `ctrl-e` | envia a marcação para o editor                          |
| `alt-u`  | desfaz a última operação aplicada nesta sessão          |
| `Esc`    | sai                                                     |

Opções: `--editor <cmd>`, `--max-depth <n>`, `--icons`, `--no-color`.

Para editar com uma configuração limpa, passe o editor com os argumentos que
quiser: `lst-f --editor "vim -u NONE"`.

## Remoção

Apagar a linha no buffer remove a entrada, mas nada é apagado durante a
aplicação: o que sai vai por `rename()` para `.lst-f-<pid>/` no diretório-base,
no mesmo modelo de arquivo de swap do Vim. Enquanto a sessão estiver aberta,
`alt-u` traz tudo de volta.

**Ao sair, a área é apagada e a remoção passa a ser definitiva.** O `lst-f` não
é uma lixeira: a garantia é sobre erro durante a operação e arrependimento
durante a sessão, não sobre recuperação amanhã.

Se a sessão morrer (crash, kill, queda de SSH), a área fica para trás e o
`lst-f` avisa na abertura seguinte daquele diretório, sem restaurar nem apagar
sozinho.

## Desenvolvimento

```sh
zig build         # compila
zig build test    # roda a suíte
zig fmt .         # formata
```
