# Desempenho

## Os números

| | RAM (PSS) | CPU parado | Binário |
|---|---|---|---|
| Vesktop (Electron) | 1.279 MB | 12–47% ¹ | 287 MB |
| **larperCord** ² | **44–47 MB** | **0–0,4%** | **~6 MB** |

¹ Média desde a abertura, medida com `ps`. Arch Linux, Hyprland, GTX 1050 Ti, janela de 1280×800, build `ReleaseFast`.

² Dados de demonstração, os 11 temas, GPU de verdade, janela de verdade num workspace escondido do Hyprland e reprodução automática de GIFs desligada. Uma janela à vista pode medir diferente.

Leia esses números com as ressalvas certas:

- **Uma conta real usa mais** do que os dados de demonstração. Mais servidores, mais membros, mais imagens.
- **Parado quer dizer que nada está se mexendo.** Um GIF animado na tela custa cerca de 2,5% de CPU. O primeiro canal da demonstração tem um, então a medição desliga a reprodução automática.
- **Boa parte do PSS não é do app.** É o driver da NVIDIA e bibliotecas do sistema como libcurl e OpenSSL. Numa medição entre os temas, a memória anônima ficou em cerca de 25 MB.
- **O binário não inclui as bibliotecas compartilhadas**, como SDL3 e libcurl.
- Os números do Vesktop vêm de uma única execução anterior na mesma máquina.

## Meça você mesmo

```bash
tools/membench.sh 60
```

Para cada tema, ele abre o app em modo demonstração com configurações limpas e a reprodução automática de GIFs desligada, espera, mede a CPU parada durante 5 segundos, lê o PSS em `/proc/<pid>/smaps_rollup` e falha se algum tema passar do orçamento em MB. Por causa dessa variação, o `terminal` às vezes falha com 60.

A página Desempenho nas configurações mostra números ao vivo, e o `--stats` mostra o tempo até o primeiro quadro.

## Dez decisões

1. **Dorme quando nada acontece.** O laço espera em `SDL_WaitEvent`. Rede, inotify e o relógio acordam o app por eventos. Sem animação, sem redesenho.
2. **Nada de navegador.** Tudo é desenhado com o `ImDrawList` do Dear ImGui sobre o SDL_Renderer.
3. **Fontes mapeadas, não copiadas.** Cada arquivo de fonte vira um `mmap` usado por todos os pesos e famílias, então só as páginas lidas ficam na RAM. Carregar 4 pesos do Inter mais emoji do jeito ingênuo custava cerca de 90 MB.
4. **Só o driver de vídeo necessário.** Em máquinas só com NVIDIA, o glvnd também carregava o Mesa e o LLVM (cerca de 23 MB) à toa. O app detecta isso e evita.
5. **Markdown interpretado uma vez**, quando a mensagem chega. A interface só faz o layout dos trechos, com cache de altura por largura.
6. **Lista virtualizada.** Busca binária pelo primeiro item visível, depois desenha só a tela.
7. **Memória com teto.** 1.500 mensagens por canal e 3.000 no total, e depois disso a conversa vista há mais tempo é descarregada. As imagens têm um orçamento fixo de 64 MB, e qualquer download isolado para em 32 MB.
8. **O fontconfig é liberado** depois que as fontes são resolvidas (`FcFini` e `malloc_trim`).
9. **Sem cursor piscando.** Ele manteria a CPU acordada à toa.
10. **As coisas começam quando você pede.** A thread de voz na primeira call e o FFmpeg no primeiro vídeo. O vídeo fora da tela é liberado depois de 30 segundos, e sem plugins não há trabalho extra por mensagem, tecla ou quadro.

## O orçamento no CI

A suíte de testes cobre as partes puras, e um job separado compila o app inteiro e roda o QA completo fora da tela. Veja [Contribuindo](page:contributing).
