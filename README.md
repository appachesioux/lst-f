# lst-f

Explora e altera o filesystem no terminal. **A tela é o buffer do seu Vim ou
Neovim**: o `lst-f` abre o diretório como um buffer editável, você edita, salva,
e ele executa o que você escreveu.

```
# lst-f v26.8.21  ·  ~/Devel/lst-f
#
# edite o caminho = renomeia ou move  ·  apague a linha = remove
# o ID casa a linha com a entrada: reordenar ou :sort e inofensivo
# :cd <dir>  ·  :find [termo]  ·  :undo  ·  :quit    (:cq aborta sem aplicar)
#
0001  src/
0002  build.zig
0003  relatorio.pdf
0004  notas antigas.txt
```

O ID à esquerda casa a linha com a entrada, então reordenar, rodar `:sort` ou
recolar linhas é inofensivo. Nada é gravado sem diff e confirmação, e as
remoções têm confirmação separada.

Sem plugin, sem gerenciador de pacotes: funciona com `vim` puro no servidor em
que você acabou de entrar por SSH.

## O que faz

| você escreve                        | acontece                                  |
| ----------------------------------- | ----------------------------------------- |
| muda o caminho de uma linha          | renomeia ou move (cria os pais que faltam) |
| apaga a linha                        | remove, via área de sessão                 |
| `:cd <dir>`                          | entra no diretório (`..` sobe)             |
| `:find [termo]`                      | busca fuzzy na árvore com o `fzf`          |
| `:undo`                              | desfaz a última operação da sessão         |
| `:quit`                              | sai (salvar sem mudanças também sai)       |
| `:cq` no editor                      | aborta sem aplicar nada                    |

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

- Vim ou Neovim, apontado por `$VISUAL` ou `$EDITOR` — é a tela, não é opcional
- `fzf` 0.17 ou mais novo, só para o `:find`
- Zig 0.16.x para compilar

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
