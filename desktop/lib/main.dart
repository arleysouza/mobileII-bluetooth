import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UniversalBle.setLogLevel(
    kDebugMode ? BleLogLevel.verbose : BleLogLevel.none,
  );
  UniversalBle.timeout = const Duration(seconds: 12);

  runApp(const ConnectionDesktopApp());
}

class ConnectionDesktopApp extends StatelessWidget {
  const ConnectionDesktopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Conexao Desktop',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const ConnectionDesktopScreen(),
    );
  }
}

class ConnectionDesktopScreen extends StatefulWidget {
  const ConnectionDesktopScreen({super.key, this.configurarBluetooth = true});

  final bool configurarBluetooth;

  @override
  State<ConnectionDesktopScreen> createState() =>
      _ConnectionDesktopScreenState();
}

enum _AcaoMenu { buscarCelulares, buscarNotebooks }

enum _TipoBusca { celulares, notebooks }

class _ConnectionDesktopScreenState extends State<ConnectionDesktopScreen> {
  static const String _serviceId = 'br.sp.gov.cps.dsm.chat';
  static const String _serviceUuid = '07eab2e6-fc51-5e32-a09b-788f502b8ed7';
  static const String _messageCharacteristicUuid =
      '6dff0753-7a8e-57d7-9858-f4f4c781cb81';
  static const String _notifyCharacteristicUuid =
      '8bc8e5cf-54eb-59ff-a05d-f94177f07f8d';

  final String _nomeUsuario = 'Notebook ${Random().nextInt(9000) + 1000}';
  final TextEditingController _mensagemController = TextEditingController();
  final List<_MensagemChat> _mensagens = [];
  final Map<String, BleDevice> _aparelhosEncontrados = {};
  final Map<String, BleDevice> _aparelhosConectados = {};
  final Map<String, String> _clientesPeripheral = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  AvailabilityState? _estadoBluetooth;
  bool _anunciando = false;
  bool _procurando = false;
  bool _conectando = false;
  _TipoBusca? _tipoBusca;
  String? _mensagemErro;

  @override
  void initState() {
    super.initState();
    if (widget.configurarBluetooth) {
      _configurarBluetooth();
    }
  }

  Future<void> _configurarBluetooth() async {
    _subscriptions.add(
      UniversalBle.availabilityStream.listen((estado) {
        if (!mounted) return;
        setState(() => _estadoBluetooth = estado);
      }),
    );

    _subscriptions.add(
      UniversalBle.scanStream.listen((device) {
        if (!mounted ||
            _aparelhosConectados.containsKey(device.deviceId) ||
            !_anunciaServicoChat(device)) {
          return;
        }

        setState(() {
          _aparelhosEncontrados[device.deviceId] = device;
        });
      }),
    );

    UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
      if (!mounted) return;

      setState(() {
        if (!isConnected) {
          final nome =
              _aparelhosConectados.remove(deviceId)?.name ?? 'Aparelho';
          _mostrarMensagem('$nome desconectou.');
        }
        if (error != null && error.isNotEmpty) {
          _mensagemErro = error;
        }
      });
    };

    UniversalBle.onValueChange = (deviceId, characteristicId, value, _) {
      if (characteristicId.toLowerCase() != _notifyCharacteristicUuid) return;
      _adicionarMensagemRecebida(deviceId, value);
    };

    UniversalBlePeripheral.setWriteRequestHandlers((
      deviceId,
      characteristicId,
      offset,
      value,
    ) {
      if (characteristicId.toLowerCase() == _messageCharacteristicUuid &&
          value != null) {
        _adicionarMensagemRecebida(deviceId, value);
      }
      return PeripheralWriteRequestResult();
    });

    UniversalBlePeripheral.setReadRequestHandlers(
      (_, _, _, value) =>
          PeripheralReadRequestResult(value: value ?? Uint8List(0)),
    );

    _subscriptions.add(
      UniversalBlePeripheral.connectionStateStream.listen((event) {
        if (!mounted) return;
        setState(() {
          if (event.connected) {
            _clientesPeripheral[event.deviceId] = event.deviceId;
          } else {
            final nome =
                _clientesPeripheral.remove(event.deviceId) ?? 'Aparelho';
            _mostrarMensagem('$nome desconectou.');
          }
        });
      }),
    );

    _subscriptions.add(
      UniversalBlePeripheral.advertisingStateStream.listen((event) {
        if (!mounted) return;
        setState(() {
          _anunciando = event.state == PeripheralAdvertisingState.advertising;
          _mensagemErro = event.error;
        });
      }),
    );

    await _atualizarEstadoBluetooth();
    if (mounted) {
      await _garantirDisponibilidade();
    }
  }

  Future<void> _atualizarEstadoBluetooth() async {
    try {
      final estado = await UniversalBle.getBluetoothAvailabilityState();
      if (!mounted) return;
      setState(() => _estadoBluetooth = estado);
    } catch (erro) {
      _definirErro('Nao foi possivel consultar o Bluetooth: $erro');
    }
  }

  Future<void> _garantirDisponibilidade() async {
    if (_anunciando || _procurando) return;
    await _iniciarAnuncio();
  }

  Future<void> _iniciarAnuncio() async {
    try {
      final caps = await UniversalBlePeripheral.getCapabilities();
      if (!caps.supportsPeripheralMode) {
        _definirErro('Este sistema nao suporta modo periferico BLE.');
        return;
      }

      final readiness = await UniversalBlePeripheral.getAvailabilityState();
      if (readiness != PeripheralReadinessState.ready) {
        _definirErro(
          'Bluetooth indisponivel para anunciar: ${readiness.name}.',
        );
        return;
      }

      await UniversalBlePeripheral.clearServices();
      await UniversalBlePeripheral.addService(
        BlePeripheralService(
          uuid: _serviceUuid,
          primary: true,
          characteristics: [
            BlePeripheralCharacteristic(
              uuid: _messageCharacteristicUuid,
              properties: [
                CharacteristicProperty.write,
                CharacteristicProperty.writeWithoutResponse,
              ],
              permissions: [PeripheralAttributePermission.writeable],
            ),
            BlePeripheralCharacteristic(
              uuid: _notifyCharacteristicUuid,
              properties: [
                CharacteristicProperty.read,
                CharacteristicProperty.notify,
              ],
              permissions: [
                PeripheralAttributePermission.readable,
                PeripheralAttributePermission.writeable,
              ],
            ),
          ],
        ),
      );

      await UniversalBlePeripheral.startAdvertising(
        services: await UniversalBlePeripheral.getServices(),
        localName: defaultTargetPlatform == TargetPlatform.windows
            ? null
            : _nomeUsuario,
      );

      if (!mounted) return;
      setState(() => _anunciando = true);
    } catch (erro) {
      _definirErro('Nao foi possivel anunciar este computador: $erro');
    }
  }

  Future<void> _pararAnuncio() async {
    await UniversalBlePeripheral.stopAdvertising();
    if (!mounted) return;
    setState(() => _anunciando = false);
  }

  Future<void> _alternarBusca(_TipoBusca tipo) async {
    _limparErro();

    if (_procurando) {
      await UniversalBle.stopScan();
      if (!mounted) return;
      if (_tipoBusca == tipo) {
        setState(() {
          _procurando = false;
          _tipoBusca = null;
        });
        await _garantirDisponibilidade();
        return;
      }
    }

    try {
      await UniversalBle.requestPermissions();
      await _atualizarEstadoBluetooth();

      if (_anunciando) {
        await _pararAnuncio();
      }
      if (!mounted) return;

      setState(() {
        _aparelhosEncontrados.clear();
        _procurando = true;
        _tipoBusca = tipo;
      });

      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [_serviceUuid]),
      );
    } catch (erro) {
      setState(() {
        _procurando = false;
        _tipoBusca = null;
      });
      _definirErro('Nao foi possivel procurar aparelhos: $erro');
      await _garantirDisponibilidade();
    }
  }

  Future<void> _conectar(BleDevice aparelho) async {
    if (_conectando) return;
    _limparErro();

    try {
      setState(() => _conectando = true);

      if (_procurando) {
        await UniversalBle.stopScan();
      }

      await UniversalBle.connect(aparelho.deviceId);
      await UniversalBle.discoverServices(
        aparelho.deviceId,
        withDescriptors: true,
      );
      await UniversalBle.subscribeNotifications(
        aparelho.deviceId,
        _serviceUuid,
        _notifyCharacteristicUuid,
      );

      if (!mounted) return;
      setState(() {
        _procurando = false;
        _tipoBusca = null;
        _aparelhosEncontrados.remove(aparelho.deviceId);
        _aparelhosConectados[aparelho.deviceId] = aparelho;
      });
      await _garantirDisponibilidade();
      _mostrarMensagem('Conectado.');
    } catch (erro) {
      _definirErro(
        'Falha ao conectar. Busque novamente e tente de novo. $erro',
      );
      await _garantirDisponibilidade();
    } finally {
      if (mounted) {
        setState(() => _conectando = false);
      }
    }
  }

  Future<void> _enviarMensagem() async {
    final texto = _mensagemController.text.trim();
    if (texto.isEmpty || !_possuiConexao) return;

    final bytes = Uint8List.fromList(utf8.encode(texto));

    for (final deviceId in _aparelhosConectados.keys) {
      await UniversalBle.write(
        deviceId,
        _serviceUuid,
        _messageCharacteristicUuid,
        bytes,
      );
    }

    if (_clientesPeripheral.isNotEmpty) {
      await UniversalBlePeripheral.updateCharacteristicValue(
        characteristicId: _notifyCharacteristicUuid,
        value: bytes,
      );
    }

    setState(() {
      _mensagens.add(
        _MensagemChat(
          texto: texto,
          remetente: _nomeUsuario,
          enviadaPorMim: true,
        ),
      );
      _mensagemController.clear();
    });
  }

  void _adicionarMensagemRecebida(String deviceId, Uint8List value) {
    final texto = utf8.decode(value, allowMalformed: true).trim();
    if (texto.isEmpty || !mounted) return;

    final nome =
        _aparelhosConectados[deviceId]?.name ??
        _clientesPeripheral[deviceId] ??
        'Aparelho';

    setState(() {
      _mensagens.add(
        _MensagemChat(texto: texto, remetente: nome, enviadaPorMim: false),
      );
    });
  }

  bool get _possuiConexao =>
      _aparelhosConectados.isNotEmpty || _clientesPeripheral.isNotEmpty;

  int get _totalConectados =>
      _aparelhosConectados.length + _clientesPeripheral.length;

  bool _anunciaServicoChat(BleDevice device) {
    return device.services.any(
      (service) => service.toLowerCase() == _serviceUuid,
    );
  }

  void _limparErro() {
    setState(() => _mensagemErro = null);
  }

  void _definirErro(String mensagem) {
    if (!mounted) return;
    setState(() => _mensagemErro = mensagem);
  }

  void _mostrarMensagem(String mensagem) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(mensagem)));
  }

  @override
  void dispose() {
    _mensagemController.dispose();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    UniversalBle.stopScan();
    UniversalBlePeripheral.stopAdvertising();
    UniversalBlePeripheral.clearServices();
    for (final deviceId in _aparelhosConectados.keys.toList()) {
      unawaited(UniversalBle.disconnect(deviceId));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aparelhos = _aparelhosEncontrados.values.toList()
      ..sort((a, b) => (a.name ?? a.deviceId).compareTo(b.name ?? b.deviceId));
    final tituloBusca = switch (_tipoBusca) {
      _TipoBusca.celulares => 'Celulares encontrados',
      _TipoBusca.notebooks => 'Notebooks encontrados',
      null => 'Aparelhos encontrados',
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Conexao Bluetooth'),
        actions: [
          PopupMenuButton<_AcaoMenu>(
            onSelected: (acao) {
              switch (acao) {
                case _AcaoMenu.buscarCelulares:
                  _alternarBusca(_TipoBusca.celulares);
                case _AcaoMenu.buscarNotebooks:
                  _alternarBusca(_TipoBusca.notebooks);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _AcaoMenu.buscarCelulares,
                child: ListTile(
                  leading: Icon(Icons.smartphone),
                  title: Text(
                    _procurando && _tipoBusca == _TipoBusca.celulares
                        ? 'Parar busca de celulares'
                        : 'Buscar celulares',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _AcaoMenu.buscarNotebooks,
                child: ListTile(
                  leading: Icon(Icons.computer),
                  title: Text(
                    _procurando && _tipoBusca == _TipoBusca.notebooks
                        ? 'Parar busca de notebooks'
                        : 'Buscar notebooks',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _PainelConexao(
              nomeUsuario: _nomeUsuario,
              serviceId: _serviceId,
              estadoBluetooth: _estadoBluetooth?.name ?? 'desconhecido',
              anunciando: _anunciando,
              procurando: _procurando,
              tipoBusca: _tipoBusca,
              conectados: _totalConectados,
            ),
            const _AvisoCompatibilidade(),
            if (_mensagemErro != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _mensagemErro!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 360,
                    child: _ListaAparelhos(
                      titulo: tituloBusca,
                      aparelhos: aparelhos,
                      conectando: _conectando,
                      onConectar: _conectar,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: _Chat(
                      mensagens: _mensagens,
                      controller: _mensagemController,
                      conectado: _possuiConexao,
                      onEnviar: _enviarMensagem,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PainelConexao extends StatelessWidget {
  const _PainelConexao({
    required this.nomeUsuario,
    required this.serviceId,
    required this.estadoBluetooth,
    required this.anunciando,
    required this.procurando,
    required this.tipoBusca,
    required this.conectados,
  });

  final String nomeUsuario;
  final String serviceId;
  final String estadoBluetooth;
  final bool anunciando;
  final bool procurando;
  final _TipoBusca? tipoBusca;
  final int conectados;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(nomeUsuario, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Bluetooth: $estadoBluetooth'),
          Text('ServiceId: $serviceId'),
          Text(
            anunciando
                ? 'Status: disponivel para conexoes'
                : procurando
                ? 'Status: buscando ${tipoBusca == _TipoBusca.notebooks ? 'notebooks' : 'celulares'}'
                : 'Status: indisponivel',
          ),
          Text('Conectados: $conectados'),
        ],
      ),
    );
  }
}

class _AvisoCompatibilidade extends StatelessWidget {
  const _AvisoCompatibilidade();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Para o notebook encontrar o celular, deixe o celular em Disponivel. '
        'Depois procure no desktop pelo nome salvo no celular. Se o celular apenas buscar o notebook, '
        'ele conecta como cliente e nao aparece na busca do desktop.',
        style: TextStyle(color: colorScheme.onSecondaryContainer),
      ),
    );
  }
}

class _ListaAparelhos extends StatelessWidget {
  const _ListaAparelhos({
    required this.titulo,
    required this.aparelhos,
    required this.conectando,
    required this.onConectar,
  });

  final String titulo;
  final List<BleDevice> aparelhos;
  final bool conectando;
  final ValueChanged<BleDevice> onConectar;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(titulo, style: Theme.of(context).textTheme.titleMedium),
        ),
        Expanded(
          child: aparelhos.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Nenhum aparelho encontrado.'),
                  ),
                )
              : ListView.builder(
                  itemCount: aparelhos.length,
                  itemBuilder: (context, index) {
                    final aparelho = aparelhos[index];
                    final nome = aparelho.name?.isNotEmpty == true
                        ? aparelho.name!
                        : 'Aparelho sem nome';
                    final servicos = aparelho.services.isEmpty
                        ? 'sem servicos anunciados'
                        : 'servicos: ${aparelho.services.join(', ')}';

                    return ListTile(
                      leading: const Icon(Icons.devices),
                      title: Text(nome),
                      subtitle: Text(
                        [
                          aparelho.deviceId,
                          if (aparelho.rssi != null) 'RSSI ${aparelho.rssi}',
                          servicos,
                        ].join(' | '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Conectar',
                        onPressed: conectando
                            ? null
                            : () => onConectar(aparelho),
                        icon: conectando
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.link),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Chat extends StatelessWidget {
  const _Chat({
    required this.mensagens,
    required this.controller,
    required this.conectado,
    required this.onEnviar,
  });

  final List<_MensagemChat> mensagens;
  final TextEditingController controller;
  final bool conectado;
  final VoidCallback onEnviar;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: mensagens.isEmpty
              ? const Center(
                  child: Text('Conecte um aparelho para iniciar o chat.'),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: mensagens.length,
                  itemBuilder: (context, index) {
                    final mensagem = mensagens[index];
                    final alinhamento = mensagem.enviadaPorMim
                        ? Alignment.centerRight
                        : Alignment.centerLeft;
                    final cor = mensagem.enviadaPorMim
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest;

                    return Align(
                      alignment: alinhamento,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 520),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cor,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              mensagem.remetente,
                              style: Theme.of(context).textTheme.labelMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(mensagem.texto),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: conectado,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Digite uma mensagem',
                  ),
                  onSubmitted: conectado ? (_) => onEnviar() : null,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Enviar',
                onPressed: conectado ? onEnviar : null,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MensagemChat {
  const _MensagemChat({
    required this.texto,
    required this.remetente,
    required this.enviadaPorMim,
  });

  final String texto;
  final String remetente;
  final bool enviadaPorMim;
}
