# O que mudou em cada versão

## 0.5.0

**Windows**
- O larperCord agora roda no Windows 10 e 11, a partir do mesmo código.
- Os tokens ficam no Gerenciador de Credenciais do Windows.

**Atualizações**
- Verifica se há versão nova ao abrir ou em Configurações → Atualizações.
- Um botão baixa, instala e reinicia. As atualizações são assinadas, e uma versão sem a assinatura certa não é instalada.
- Botão de reiniciar nas Configurações, e esta página.

**Voz**
- Supressão de ruído no microfone com RNNoise, ligada por padrão e trocável em plena call. Não roda com a tecla do aperte para falar solta.
- Menos engasgos e nada de estalos quando um pacote se perde ou chega fora de ordem; a folga de áudio cresce quando a rede engasga.
- As pessoas não somem mais por um instante quando alguém entra ou sai da call.
- Quando a rede trava, a voz se apaga em vez de cortar no meio da palavra, e volta sem estalo.
- A pausa da porta de ruído de alguém não é mais tratada como rede ruim, o que mantém o atraso do áudio baixo.
- A supressão de ruído usa menos CPU nas versões publicadas: ela escolhe o caminho mais rápido para o seu processador ao rodar.

**Bandeja**
- Fechar e reabrir não empilha mais ícones na bandeja. No Linux o ícone fica num processo pequeno à parte, que só existe com a janela escondida, e o GTK fica fora do app.

**Layout**
- Arraste a borda da lista de canais, da lista de membros ou dos painéis da tela dividida para mudar a largura. Duplo clique volta à largura do tema, e a sua escolha fica salva e vale nos outros temas.
- Conversa estreita continua funcionando: a caixa de busca sai antes dos botões.

**Mensagens**
- Etiqueta BOT ao lado do nome de bots e webhooks, com um ✓ nos bots verificados, nas mensagens, na lista de membros, nas DMs e nos perfis.
- Mensagens de webhook ficam com o nome e a foto com que cada uma foi enviada.
- Mensagens de bot no formato novo de componentes, que apareciam em branco. Encaminhadas e enquetes aparecem como cartões.
- O texto de embeds pode ser selecionado e copiado.
- Markdown do Discord: títulos, texto pequeno, citações, listas e links `[texto](url)`. Número de linha nos blocos de código.
- A seleção de texto dentro de um bloco de código agora aparece.
- Esc cancela a edição de uma mensagem.
- Botão direito ou do meio não dispara mais o clique normal de um botão. Na barra de ações da mensagem, por exemplo, ele adicionava a reação.
- Erros no código enquanto digita um bloco, opcional, com o servidor de linguagem que você escolher.

**Servidores e grupos**
- Editar um servidor (nome, descrição, ícone, banner) ou um grupo de DM (nome, ícone).
- Excluir threads.
- Banner do servidor no topo da lista de canais e nos cartões de convite.
- Clique no banner de um servidor para ver a imagem inteira, e o mesmo no banner de um perfil. Os menus do servidor e da pessoa também abrem o ícone ou a foto.
- Ícones de amigos, de grupo e do alfinete redesenhados.

**Plugins**
- Os plugins agora rodam numa thread só deles: um lento ou travado não engasga a interface, e é parado com o erro no cartão. Sem plugin ligado, a thread nem existe e nenhum Lua é carregado.
- Plugins novos que vêm com o app: favoritos, lembretes, destaques, filtro local, trechos, tradução e estatísticas do canal. Configurações → Plugins instala, sem mexer nos seus arquivos.
- Configurações → Plugins mostra um cartão para cada plugin, a partir de um cabeçalho no começo do arquivo: nome, descrição, versão, o que ele pede, erros e um jeito de abrir o painel, mesmo desligado.
- O que os plugins podem fazer agora: painéis numa lateral que se encaixa de qualquer lado, entradas no botão direito de mensagens e pessoas, selos, notas e recolher com "mostrar" embaixo das mensagens, dados próprios, temporizadores, notificações do sistema, mensagens carregadas, pular para uma mensagem e pôr texto na caixa de mensagem.
- HTTPS opcional para plugins, só para os hosts que você aprovar um a um, sem cookies, token nem cabeçalhos do Discord.
- Os arquivos que já estavam na pasta de plugins continuam funcionando, e os exemplos das versões antigas não são apagados.

**Mais leve**
- Executável menor, abertura mais rápida e menos memória.

## 0.4.0

Primeira versão pública: conexão real com o Discord, voz com criptografia de ponta a ponta, threads e fóruns, leitura sincronizada, busca, plugins em Lua e 11 temas.
