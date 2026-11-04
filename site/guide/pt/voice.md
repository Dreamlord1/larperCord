# Chamadas de voz

O larperCord entra em canais de voz de verdade do Discord, com criptografia de ponta a ponta. Tudo que é de voz roda numa thread própria, criada só quando você entra numa call. Fora de uma call, o módulo não usa CPU e o app nem inicializa o áudio.

## Usando

Clique num canal de voz para entrar. O painel acima do seu usuário mostra a call, com mudo, ensurdecer e desconectar. Você também pode sair por "Sair da call", clicando com o botão direito no canal de voz. Quem está falando ganha um anel em volta do avatar.

O **mixer** dá a cada pessoa o próprio volume.

![O mixer da call](shot:f-voz)

Os canais em que você não tem permissão para conectar aparecem com cadeado, e o app nem tenta.

## Como funciona

| Camada | O que usa |
|---|---|
| Sinalização | Gateway de voz v8 por WebSocket, com heartbeat (`seq_ack`) e RESUME quando a conexão cai |
| Conexão | IP discovery (pacote de 74 bytes) e Select Protocol por UDP |
| Criptografia de transporte | RTP com `aead_xchacha20_poly1305_rtpsize` |
| Criptografia de ponta a ponta | DAVE sobre MLS, pela libdave e pelo MLSpp |
| Codec | Opus a 48 kHz estéreo, 20 ms por pacote. Pacotes perdidos viram o packet-loss concealment do Opus |
| Áudio | O SDL3 mistura. Cada pessoa é um `SDL_AudioStream` no mesmo dispositivo de saída, e o volume dela é o ganho do stream. O microfone é um stream lido a cada 20 ms |

Alguns detalhes que deram trabalho para acertar:

- O opcode de "falando" (op 5) sai uma vez quando a sessão abre, e de novo ao retomar. Ele não liga e desliga a cada frase, porque assim o servidor descartava o começo de cada uma.
- O relógio do RTP continua andando com o tempo real enquanto você está calado, para quem recebe não descartar os seus pacotes depois de uma pausa.
- A margem de jitter vale só no começo de cada trecho de fala. Aplicá-la sempre que a fila esvaziava causava falhas audíveis.
- Quem já está numa call pode chegar antes de o DAVE existir, então essas pessoas são guardadas e adicionadas quando ele começa.

## Limites hoje

- Usa o dispositivo de áudio padrão do sistema. Ainda não há seletor de dispositivo.
- Sem push-to-talk e sem supressão de ruído.
- Sem compartilhamento de tela, câmera nem transmissão.
- Sem teste automático para uma call de verdade. O QA cobre só a interface.

## Depuração

```bash
LARPER_VOICE_DEBUG=1 larpercord
```

Isso imprime opcodes, códigos de fechamento e eventos do DAVE, além do nível do microfone e dos quadros enviados. Nunca imprime o token nem chaves.

Para testar só a conexão, o `--voice-test` entra num canal por 25 segundos, **sempre mudo**:

```bash
LARPER_TOKEN=... larpercord --voice-test GUILD_ID CHANNEL_ID
```

