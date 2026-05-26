# Connection

Workspace Flutter com dois aplicativos de chat local e um pacote compartilhado:

- `app/`: aplicativo Android para celular.
- `desktop/`: aplicativo Flutter desktop para notebook.
- `shared/`: pacote Dart local com o contrato comum de mensagens.

Os dois aplicativos usam o mesmo protocolo de mensagens para manter historico, reenviar mensagens pendentes e indicar os estados `Digitada`, `Recebida` e `Aberta`.

## Estrutura

```text
connection/
|-- app/
|   |-- android/
|   |-- lib/
|   |   |-- app/
|   |   |-- core/platform/
|   |   `-- features/connection/
|   |       |-- data/
|   |       |-- models/
|   |       `-- widgets/
|   `-- test/
|-- desktop/
|   |-- lib/
|   |   `-- features/connection/
|   |       |-- data/
|   |       |-- models/
|   |       `-- widgets/
|   |-- test/
|   `-- windows/
`-- shared/
    `-- lib/
        `-- src/
```

## Pacote compartilhado

O pacote `shared/` concentra o contrato que precisa ser igual no celular e no notebook:

- `MessageStatus`: estados da mensagem.
- `MessagePacket`: pacote individual recebido ou enviado.
- `MessageProtocol`: codificacao e decodificacao JSON.
- `MessageBatchItem`: item usado no envio em lote.

Os apps importam esse pacote por dependencia local:

```yaml
connection_shared:
  path: ../shared
```

## Comunicacao

O identificador logico da aplicacao e:

```dart
br.sp.gov.cps.dsm.chat
```

Para a comunicacao BLE entre celular e notebook, os apps usam UUIDs derivados desse identificador:

- Service UUID BLE: `07eab2e6-fc51-5e32-a09b-788f502b8ed7`
- Caracteristica de escrita: `6dff0753-7a8e-57d7-9858-f4f4c781cb81`
- Caracteristica de notificacao: `8bc8e5cf-54eb-59ff-a05d-f94177f07f8d`

O celular tambem mantem um servico em primeiro plano para continuar disponivel para localizacao e conversa enquanto o app nao esta aberto na tela.

## Pre-requisitos

Instale e configure o Flutter SDK. Depois confirme o ambiente:

```bash
flutter doctor
```

Para Android:

- Android Studio ou Android SDK instalado.
- Um celular Android real com depuracao USB ativada.
- Bluetooth, Wi-Fi e localizacao ativados no celular.
- Permissoes solicitadas pelo app concedidas no primeiro uso.

Para Windows desktop:

- Visual Studio 2022 Community, Professional ou Enterprise.
- Workload `Desktop development with C++`.
- Componentes de CMake e Windows SDK selecionados pelo instalador.

Sem o Visual Studio com C++, o comando `flutter run -d windows` nao compila o app do notebook.

## Rodar no celular

Conecte o celular por USB e confirme que ele aparece na lista de dispositivos:

```bash
flutter devices
```

Prepare e execute o app Android:

```bash
cd app
flutter pub get
flutter run
```

Se houver mais de um dispositivo conectado, informe o id:

```bash
flutter run -d <id-do-celular>
```

O app mobile fica fixo em orientacao vertical. Ao abrir, conceda as permissoes solicitadas e mantenha Bluetooth, Wi-Fi e localizacao ligados.

## Rodar no notebook

No Windows, execute o app desktop:

```bash
cd desktop
flutter pub get
flutter run -d windows
```

Se estiver usando outro sistema com suporte Flutter desktop configurado, troque o destino:

```bash
flutter run -d linux
flutter run -d macos
```

## Fluxo de teste entre celular e notebook

1. Rode o app no celular.
2. Rode o app no notebook.
3. No notebook ou no celular, use as opcoes de busca para localizar celulares ou notebooks.
4. Selecione o dispositivo encontrado.
5. Envie mensagens pelo campo de chat.
6. Verifique os estados das mensagens:
   - `Digitada`: mensagem registrada localmente, ainda pendente de envio.
   - `Recebida`: mensagem entregue ao dispositivo de destino.
   - `Aberta`: conversa aberta no app de destino.

As mensagens ficam persistidas localmente. Ao reconectar com um dispositivo conhecido, mensagens pendentes podem ser reenviadas em lote.

## Comandos uteis

Formatar os tres projetos:

```bash
dart format app/lib app/test desktop/lib desktop/test shared/lib
```

Analisar:

```bash
cd app && flutter analyze
cd ../desktop && flutter analyze
cd ../shared && dart analyze
```

Testar:

```bash
cd app && flutter test
cd ../desktop && flutter test
```

## Observacoes

- A versao Web/Chrome nao e alvo deste projeto, pois a comunicacao depende de APIs nativas.
- Logs de recursos indisponiveis do aparelho, como NFC, podem ser ignorados se nao forem relacionados ao Bluetooth.
- Se permissoes antigas ficarem presas durante testes Android, desinstale o app do celular e instale novamente.
