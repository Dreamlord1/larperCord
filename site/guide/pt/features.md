# Tour de recursos

Tudo aqui funciona no modo demonstração, exceto onde precisa da rede de verdade. Para o que falta ou está parcial, veja [Estado e roadmap](page:status).

## Conversas

- **Mensagens**: enviar, editar (`↑` na caixa vazia edita a última), excluir, e mensagens pendentes confirmadas pelo servidor. As mensagens são agrupadas, com separadores de dia.
- **Respostas**, com a curvinha e um clique que pula até a original.
- **Reações**, um seletor de emoji e uma barra de ações ao passar o mouse em cada mensagem.
- **Seleção de texto** entre várias mensagens com o mouse, depois `Ctrl+C`.
- **Caixa de texto com várias linhas**: quebra o texto longo e cresce até 10 linhas. `Enter` envia e `Shift+Enter` abre uma linha nova.
- **Rascunhos** por canal: o texto não enviado volta quando você retorna ao canal, mesmo depois de fechar o app.
- **Histórico** carregado conforme você rola para cima, sem a tela pular, numa lista virtualizada.
- **Mensagens de sistema**: entradas, calls, fixadas, boosts.
- **Registro de mensagens** (opcional): as mensagens apagadas continuam na tela, marcadas, e as edições guardam o original. Só local.

## Markdown

**Negrito**, *itálico*, ~~riscado~~, `código`, spoilers, menções `<@id>` e `<#id>`, links e emoji colorido. Os blocos de código ganham realce nas cores do tema a partir da etiqueta do bloco (zig, c/cpp, js/ts, py, rust, go, sh, json, lua, java/kotlin, c#, diff) e um botão **Copiar**. Opcionalmente, uma prévia ao vivo fica acima da caixa de texto enquanto você digita.

## Mídia

- **Imagens** e **GIFs**, com cache de tamanho fixo, visualização em tela cheia e envio pelo seletor, arrastando e soltando ou com `Ctrl+V`. WebP e APNG animado também são decodificados.
- **Embeds** como cartões: cor, autor, título, descrição em markdown, campos, imagem, miniatura e rodapé.
- **Vídeo na conversa** para anexos e links diretos `.mp4`/`.webm`, pelo FFmpeg do sistema, que só é carregado no primeiro play. Play e pausa, barra de progresso e som, até 854×480 a cerca de 30 qps. O vídeo fora da tela pausa, e 30 segundos depois tudo é liberado. Sem o FFmpeg, ele abre no navegador.
- **Modo economia**: imagens, fotos de perfil e anexos só baixam quando você clica.

## Achando as coisas

- **Paleta de comandos** (`Ctrl+K`, ou `Ctrl+Shift+P` para ações primeiro): busca aproximada em canais, DMs, servidores, temas, status, páginas de configurações e todas as opções liga/desliga.
- **Busca** (`Ctrl+F`): roda na memória e no cache local a cada tecla, sem internet. Os resultados pulam até a mensagem.

| Filtro | Encontra |
|---|---|
| `from:nome` | mensagens dessa pessoa |
| `in:canal` | mensagens nesse canal |
| `has:link` | mensagens com um link |
| `has:imagem` | mensagens com uma imagem (`has:image` também funciona) |
| `has:arquivo` | mensagens com um arquivo (`has:file` também funciona) |
| `"frase exata"` | essa frase |

A busca ignora maiúsculas e acentos, então `nao` encontra `não`.

- **Caixa de entrada** (`Ctrl+I`): DMs e menções não lidas de todos os servidores, agrupadas por canal, com prévia, ir até a mensagem e "Marcar tudo como lido". Uma segunda aba mostra as menções recentes do Discord.
- **Mensagens salvas** (`Ctrl+Shift+S`, ou botão direito → Salvar mensagem): até 500, com uma anotação de até 1.000 caracteres. Ficam só no seu computador, e nada vai para o Discord.

## Layout

- **Abas** para os canais abertos. `Ctrl+Clique` abre um em nova aba, e o clique do meio fecha.
- **Tela dividida**: "Abrir ao lado" no menu de um canal coloca até 3 conversas lado a lado, cada uma com o próprio histórico e posição de rolagem. A caixa de texto e o cabeçalho seguem o painel em foco.
- **Esconder a lista de membros ou a barra de status** em Configurações → Aparência, e a conversa ocupa o espaço.
- **Pastas de servidores** das suas configurações do Discord, atualizadas ao vivo.
- **Tela de amigos**: pedidos, aceitar e começar DMs.

## Pessoas

- **Cartão de perfil** com banner, cor de destaque, bio em markdown, pronomes, amigos e servidores em comum, jogo atual com o tempo decorrido, e a call em que a pessoa está, com um botão Entrar.
- **Perfil completo** com abas: atividade, amigos e servidores em comum, conexões, emblemas e a sua nota privada.
- **Seletor de status**: online, ausente, não perturbe, invisível.
- **Cargos**: lista de membros por cargo com as cores reais, e dar ou tirar cargos quando você tem permissão.

## Atenção

- **Palavras de alerta** contam como menções. Até 64 palavras, procuradas como palavra inteira, sem diferenciar maiúsculas.
- **Filtro de palavras** recolhe as mensagens que combinam atrás de um clique, e elas nunca notificam.
- **Ignorar** esconde as mensagens de alguém localmente, sem bloquear.
- **Modo foco**: por 15 minutos, 30 minutos, 1 hora ou até você desligar, só DMs e menções notificam e marcam como não lido.
- **Notificações na área de trabalho** pelo `notify-send`, só com a janela fora de foco, mais a barra de tarefas piscando. Canais silenciados nunca notificam.

## Canais que você não pode abrir

O app calcula as exceções de permissão de cada canal do jeito que o Discord faz (`@everyone`, seus cargos, você). Um canal sem acesso aparece apagado, com cadeado e uma dica, e clicar só avisa isso, em vez de perguntar ao servidor. Canais de voz em que você não pode entrar têm o mesmo tratamento.

## Calls

Voz de verdade com criptografia de ponta a ponta e um mixer por pessoa. Veja [Chamadas de voz](page:voice).

## Rede e idiomas

- **Proxy** para `http`, `https`, `socks5` e `socks5h` (Tor em `socks5h://127.0.0.1:9050`), só para mídia externa ou para tudo.
- **Inglês e português** em toda a interface, nos avisos de rede, nos dados de demonstração e nas opções dos temas. Por padrão, segue o seu sistema.

## Deixe do seu jeito

- Os [temas](page:themes) reorganizam a interface inteira e recarregam ao salvar. Temas com `palette "wal"` acompanham o seu wallpaper pelo pywal, e o tema `vidro` tem fundo transparente que o seu compositor desfoca.
- Os [plugins](page:plugins) em Lua reagem a mensagens e criam comandos locais e atalhos.
- **Navegação estilo vim opcional**: veja [Atalhos](page:shortcuts).
