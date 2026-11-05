# O que mudou em cada versão

## 0.6.0

**Plugins**
- A tradução agora tem opções: idioma de destino e de origem no cartão em Configurações → Plugins, e "Traduzir para…" no botão direito para uma mensagem só. Um 🌐 na barra da mensagem, e `/tr es olá` põe uma tradução na caixa de mensagem.
- Anti-golpe marca em vermelho os golpes clássicos de Discord nas mensagens dos outros: endereços que imitam o Discord ou a Steam, Nitro grátis falso com link, links encurtados com isca. Roda no seu computador, sem rede, e endereços oficiais nunca são marcados.
- Radar de CVE acha `CVE-2021-44228` nas mensagens e mostra embaixo a severidade, a nota CVSS e um resumo, do registro oficial. Cada número é pedido uma vez, e só depois de aprovar o host.
- Cartões do GitHub põem o título, o estado e as estrelas embaixo de `dono/repo#123` e de links do GitHub.
- O que perdi resume as mensagens não lidas de um canal: quantas de cada pessoa, menções a você, perguntas sem resposta, links e arquivos, com um clique até cada um.
- Também novos: Links limpos tira o rastreio dos links que você envia, e Links e arquivos lista o que foi compartilhado no canal.
- Lembretes entendem hora e data (`/remind amanhã 9h`, `/remind todo dia 8:30`), têm uma segunda lista no botão direito, e o que já avisou pode voltar em 10 minutos.
- Destaques mostra quantos você não viu, silencia um canal, acompanha edições e pode usar as notificações do sistema.
- Favoritos, o filtro de palavras, trechos, horários, estatísticas e os plugins de demonstração não vêm mais com o app: os dois primeiros viraram funções do próprio app. Quem tem continua usando, e um botão arquiva em `plugins/antigos/`. Nada é apagado.
- Um plugin incluído com versão nova mostra um botão de atualizar no cartão, e guarda o seu arquivo como `.bak`.
- Novo para quem faz plugins: opções no cartão (`larper.settings`, `select`, `toggle`), segunda lista e botão na barra nos menus, sugestões na caixa de mensagem (`larper.completions`), regras para o que você envia (`larper.rewrite`), `larper.copy`, `larper.open`, um número na etiqueta do painel, notas em vermelho, os eventos `edit`, `dismiss` e `hosts`, um filtro `contains` que mantém as mensagens longe do Lua, e anexos, respostas, menções e a posição de leitura em `larper.messages`.
- Um plugin atrasado perde mensagens em vez de segurar os outros, e o cartão dele diz isso. Cada plugin tem o próprio limite de notificações do sistema: um barulhento não come o aviso de um lembrete.
- O cartão avisa quando um plugin lê mensagens e também consegue mandar algo para fora.
- Fechar uma tradução com o × não faz mais o próximo "Traduzir" não fazer nada.

**Mensagens**
- Horários `<t:…>` aparecem como uma data ou "em 2 horas", no seu fuso, em vez do código.
- Em cima de um link, o cursor vira a mãozinha. A seleção de texto estava passando por cima dela.
- Marcar como lida e como não lida agora sempre chega ao Discord. Com o status invisível, ficava só no seu computador e voltava na próxima conexão. O status não impede mais a confirmação de leitura; com a janela sem foco, ela continua não indo sozinha.

**Mais leve**
- Quadro que sai igual ao anterior não é desenhado de novo, então eventos da rede que não mudam nada na tela custam menos.
- Mexer o mouse sem botão apertado pede menos quadros.
- Depois de um minuto na bandeja ou minimizada, as imagens saem da memória, menos as pequenas que estavam na tela.
- Configurações → Desempenho mostra para onde vai a memória: imagens, mensagens, pessoas, servidores, fontes, driver e bibliotecas.

**Contas**
- A tela de login mostra todas as contas salvas como botões, venha de onde vier, com um aviso para usar conta secundária antes de colar um token.
- Quando o Discord recusa um token, o app esquece esse token em vez de tentar de novo a cada abertura. Se a sessão acabar com o app aberto, ele volta para a tela de login.

**Instalação**
- O instalador do Linux dá ao atalho o ID da janela, para as barras que procuram o ícone desse jeito acharem. Rodar de novo troca o atalho antigo.

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
