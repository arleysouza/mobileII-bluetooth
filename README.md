
# Exemplo Quatro

Projeto Flutter com uma tela de conexão entre dispositivos próximos e chat entre instâncias do aplicativo.

## Conexão entre aparelhos

A tela `lib/connection_screen.dart` implementa comunicação entre aparelhos próximos usando o pacote `nearby_connections`.

O recurso não faz uma busca Bluetooth genérica como a tela de configurações do Android. Ele procura outro dispositivo que esteja rodando o mesmo aplicativo, usando o mesmo identificador de serviço:

```dart
static const String _serviceId = 'br.sp.gov.cps.dsm.chat';
```

Por isso, notebooks, fones, caixas de som ou outros dispositivos Bluetooth comuns não aparecem na lista. Para testar o chat, é necessário abrir o app em dois aparelhos Android.

## Permissões

As permissões necessárias estão declaradas em `android/app/src/main/AndroidManifest.xml`.

Principais permissões usadas:

- `ACCESS_COARSE_LOCATION`
- `ACCESS_FINE_LOCATION`
- `ACCESS_WIFI_STATE`
- `CHANGE_WIFI_STATE`
- `BLUETOOTH`
- `BLUETOOTH_ADMIN`
- `BLUETOOTH_ADVERTISE`
- `BLUETOOTH_SCAN`
- `BLUETOOTH_CONNECT`
- `NEARBY_WIFI_DEVICES`

Além de estarem no Manifest, as permissões perigosas são solicitadas em tempo de execução no método `_pedirPermissoes()` da tela de conexão.

No Android, a descoberta de dispositivos próximos também exige que Bluetooth, Wi-Fi e localização estejam ativados no aparelho.

## Fluxo de funcionamento

1. O app gera um nome temporário para o dispositivo, como `Aparelho 1234`.
2. Ao tocar em `Ficar visível`, o aparelho começa a anunciar o serviço `br.sp.gov.cps.dsm.chat`.
3. Em outro aparelho, ao tocar em `Buscar aparelhos`, o app procura dispositivos próximos anunciando o mesmo serviço.
4. Quando um aparelho é encontrado, ele aparece na lista de dispositivos.
5. Ao tocar no ícone de conexão, o app envia uma solicitação de conexão.
6. Os dois aparelhos exibem uma confirmação com token de autenticação.
7. Depois que a conexão é aceita, o chat é liberado.
8. As mensagens digitadas são enviadas como payload de bytes para os aparelhos conectados.

## Como testar

Use dois aparelhos Android reais.

Em ambos os aparelhos:

- ative o Bluetooth;
- ative o Wi-Fi;
- ative a localização;
- conceda as permissões solicitadas pelo app.

Depois:

1. Instale e abra o app nos dois aparelhos.
2. No aparelho A, toque em `Ficar visível`.
3. No aparelho B, toque em `Buscar aparelhos`.
4. No aparelho B, toque no botão de conectar do aparelho encontrado.
5. Aceite a conexão nos dois aparelhos.
6. Envie mensagens pelo campo do chat.

## Observações

- A versão Web/Chrome não consegue usar essa funcionalidade nativa de proximidade.
- Logs sobre NFC, como `NFC is not supported`, podem ser ignorados se o aparelho não tiver NFC.
- Se permissões antigas ficarem presas no Android durante testes, desinstale o app e instale novamente.
