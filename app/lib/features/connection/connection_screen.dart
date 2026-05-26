import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:connection_shared/connection_shared.dart';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import '../../core/platform/connection_foreground_service.dart';

part 'models/connection_models.dart';
part 'data/message_protocol.dart';
part 'widgets/connection_widgets.dart';

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

enum _AcaoMenu { editarNome, buscarCelulares, buscarNotebooks }

enum _TipoConversa { celular, notebookCentral, notebookPeripheral }

class _ConnectionScreenState extends State<ConnectionScreen>
    with WidgetsBindingObserver {
  static const String _serviceId = 'br.sp.gov.cps.dsm.chat';
  static const String _serviceUuid = '07eab2e6-fc51-5e32-a09b-788f502b8ed7';
  static const String _messageCharacteristicUuid =
      '6dff0753-7a8e-57d7-9858-f4f4c781cb81';
  static const String _notifyCharacteristicUuid =
      '8bc8e5cf-54eb-59ff-a05d-f94177f07f8d';
  static const String _nomeUsuarioPrefsKey = 'connection_user_name';
  static const String _mensagensPrefsKey = 'connection_messages';
  static const Strategy _strategy = Strategy.P2P_CLUSTER;

  final TextEditingController _mensagemController = TextEditingController();
  final List<_AparelhoEncontrado> _aparelhosEncontrados = [];
  final Map<String, ConnectionInfo> _aparelhosConectados = {};
  final Map<String, BleDevice> _notebooksEncontrados = {};
  final Map<String, BleDevice> _notebooksConectados = {};
  final Map<String, String> _clientesBlePeripheral = {};
  final List<_MensagemChat> _mensagens = [];
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  String? _conversaSelecionadaId;
  VoidCallback? _atualizarModalBusca;

  bool _anunciando = false;
  bool _anunciandoBle = false;
  bool _alternandoDisponibilidade = false;
  bool _procurando = false;
  bool _procurandoBle = false;
  bool _conectando = false;
  bool _conectandoBle = false;
  bool _appEmPrimeiroPlano = true;
  String? _mensagemErro;
  late String _nomeUsuario;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nomeUsuario = 'Aparelho ${Random().nextInt(9000) + 1000}';
    _configurarBle();
    unawaited(_inicializarDisponibilidade());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final emPrimeiroPlano = state == AppLifecycleState.resumed;
    if (_appEmPrimeiroPlano == emPrimeiroPlano) return;

    _appEmPrimeiroPlano = emPrimeiroPlano;
    if (emPrimeiroPlano && _conversaSelecionadaId != null) {
      _marcarConversaComoAberta(_conversaSelecionadaId!);
    }
  }

  Future<void> _inicializarDisponibilidade() async {
    await _carregarNomeUsuario();
    await _carregarHistoricoMensagens();
    if (!mounted) return;
    await _garantirDisponibilidade();
  }

  Future<void> _carregarNomeUsuario() async {
    final prefs = await SharedPreferences.getInstance();
    final nomeSalvo = prefs.getString(_nomeUsuarioPrefsKey)?.trim();
    if (!mounted || nomeSalvo == null || nomeSalvo.isEmpty) return;

    setState(() => _nomeUsuario = nomeSalvo);
  }

  Future<void> _carregarHistoricoMensagens() async {
    final prefs = await SharedPreferences.getInstance();
    final historico = prefs.getString(_mensagensPrefsKey);
    if (!mounted || historico == null || historico.isEmpty) return;

    final json = jsonDecode(historico);
    if (json is! List) return;

    setState(() {
      _mensagens
        ..clear()
        ..addAll(
          json.whereType<Map>().map(
            (item) => _MensagemChat.fromJson(Map<String, dynamic>.from(item)),
          ),
        );
    });
  }

  Future<void> _persistirMensagens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _mensagensPrefsKey,
      jsonEncode(_mensagens.map((mensagem) => mensagem.toJson()).toList()),
    );
  }

  Future<void> _abrirEdicaoNome() async {
    final nome = await showDialog<String>(
      context: context,
      builder: (_) => _DialogEdicaoNome(nomeInicial: _nomeUsuario),
    );

    final nomeNormalizado = nome?.trim();
    if (nomeNormalizado == null || nomeNormalizado.isEmpty || !mounted) return;

    final estavaDisponivel = _anunciando || _anunciandoBle;
    if (estavaDisponivel) {
      await _pararAnuncio();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nomeUsuarioPrefsKey, nomeNormalizado);
    if (!mounted) return;

    setState(() => _nomeUsuario = nomeNormalizado);

    if (estavaDisponivel) {
      await _iniciarAnuncio();
    }
  }

  Future<void> _garantirDisponibilidade() async {
    if (_anunciando || _anunciandoBle || _alternandoDisponibilidade) return;
    setState(() {
      _mensagemErro = null;
      _alternandoDisponibilidade = true;
    });

    try {
      await _iniciarAnuncio();
    } catch (erro) {
      if (_erroJaEstaAnunciando(erro)) {
        if (mounted) {
          setState(() => _anunciando = true);
        }
        return;
      }
      _definirErro('Não foi possível deixar este aparelho disponível: $erro');
    } finally {
      if (mounted) {
        setState(() => _alternandoDisponibilidade = false);
      }
    }
  }

  void _configurarBle() {
    UniversalBle.timeout = const Duration(seconds: 12);

    _subscriptions.add(
      UniversalBle.scanStream.listen((device) {
        if (!mounted || _notebooksConectados.containsKey(device.deviceId)) {
          return;
        }

        setState(() {
          _notebooksEncontrados[device.deviceId] = device;
        });
        _atualizarModalBusca?.call();
      }),
    );

    UniversalBle.onConnectionChange = (deviceId, isConnected, error) {
      if (!mounted) return;

      setState(() {
        if (!isConnected) {
          final chave = _chaveNotebookCentral(deviceId);
          final nome =
              _notebooksConectados.remove(deviceId)?.name ?? 'Notebook';
          if (_conversaSelecionadaId == chave) {
            _conversaSelecionadaId = null;
          }
          _mostrarMensagem('$nome desconectou.');
        }
        if (error != null && error.isNotEmpty) {
          _mensagemErro = error;
        }
      });
    };

    UniversalBle.onValueChange = (deviceId, characteristicId, value, _) {
      if (characteristicId.toLowerCase() != _notifyCharacteristicUuid) return;
      _adicionarMensagemBle(deviceId, value);
    };

    UniversalBlePeripheral.setWriteRequestHandlers((
      deviceId,
      characteristicId,
      offset,
      value,
    ) {
      if (characteristicId.toLowerCase() == _messageCharacteristicUuid &&
          value != null) {
        _adicionarMensagemBle(deviceId, value);
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
            _clientesBlePeripheral[event.deviceId] = event.deviceId;
          } else {
            final chave = _chaveNotebookPeripheral(event.deviceId);
            final nome =
                _clientesBlePeripheral.remove(event.deviceId) ?? 'Notebook';
            if (_conversaSelecionadaId == chave) {
              _conversaSelecionadaId = null;
            }
            _mostrarMensagem('$nome desconectou.');
          }
        });
      }),
    );

    _subscriptions.add(
      UniversalBlePeripheral.advertisingStateStream.listen((event) {
        if (!mounted) return;
        setState(() {
          _anunciandoBle =
              event.state == PeripheralAdvertisingState.advertising;
          _mensagemErro = event.error;
        });
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mensagemController.dispose();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    Nearby().stopAllEndpoints();
    UniversalBle.stopScan();
    UniversalBlePeripheral.stopAdvertising();
    UniversalBlePeripheral.clearServices();
    for (final deviceId in _notebooksConectados.keys.toList()) {
      unawaited(UniversalBle.disconnect(deviceId));
    }
    super.dispose();
  }

  Future<bool> _pedirPermissoes() async {
    final localizacao = await Permission.locationWhenInUse.request();
    if (localizacao.isDenied || localizacao.isPermanentlyDenied) {
      _mostrarMensagem('Permissão de localização negada.');
      return false;
    }

    await <Permission>[
      Permission.notification,
      Permission.bluetoothAdvertise,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.nearbyWifiDevices,
    ].request();

    final localizacaoAtiva =
        await Permission.locationWhenInUse.serviceStatus.isEnabled;
    if (!localizacaoAtiva) {
      _mostrarMensagem(
        'Ative a localização do aparelho para descobrir outros dispositivos.',
      );
      return false;
    }

    return true;
  }

  Future<void> _pararAnuncio() async {
    await Nearby().stopAdvertising();
    await UniversalBlePeripheral.stopAdvertising();
    await UniversalBlePeripheral.clearServices();
    if (!mounted) return;
    setState(() {
      _anunciando = false;
      _anunciandoBle = false;
    });
  }

  Future<void> _iniciarAnuncio() async {
    if (!await _pedirPermissoes()) return;

    await ConnectionForegroundService.start();

    final iniciadoBle = await _iniciarAnuncioBle();

    var iniciado = false;
    try {
      iniciado = await Nearby().startAdvertising(
        _nomeUsuario,
        _strategy,
        serviceId: _serviceId,
        onConnectionInitiated: _aoIniciarConexao,
        onConnectionResult: _aoResultadoConexao,
        onDisconnected: _aoDesconectar,
      );
    } catch (erro) {
      if (!_erroJaEstaAnunciando(erro)) rethrow;
      iniciado = true;
    }

    if (!mounted) return;
    setState(() {
      _anunciando = iniciado;
      _anunciandoBle = iniciadoBle;
    });
  }

  Future<bool> _iniciarAnuncioBle() async {
    try {
      final caps = await UniversalBlePeripheral.getCapabilities();
      if (!caps.supportsPeripheralMode) {
        _definirErro('Este celular não suporta modo periférico BLE.');
        return false;
      }

      final readiness = await UniversalBlePeripheral.getAvailabilityState();
      if (readiness != PeripheralReadinessState.ready) {
        _definirErro('Bluetooth indisponível para BLE: ${readiness.name}.');
        return false;
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
        localName: null,
      );
      return true;
    } catch (erro) {
      if (_erroJaEstaAnunciando(erro)) {
        return true;
      }
      _definirErro('Não foi possível anunciar por BLE: $erro');
      return false;
    }
  }

  bool _erroJaEstaAnunciando(Object erro) {
    final texto = erro.toString();
    return texto.contains('STATUS_ALREADY_ADVERTISING') ||
        texto.contains('ALREADY_ADVERTISING') ||
        texto.contains('Already started');
  }

  Future<void> _alternarBusca() async {
    setState(() {
      _mensagemErro = null;
    });

    if (_procurando) {
      await Nearby().stopDiscovery();
      if (!mounted) return;
      setState(() {
        _procurando = false;
      });
      return;
    }

    if (!await _pedirPermissoes()) return;

    try {
      final iniciado = await Nearby().startDiscovery(
        _nomeUsuario,
        _strategy,
        serviceId: _serviceId,
        onEndpointFound: (id, nome, serviceId) {
          if (serviceId != _serviceId) return;

          setState(() {
            final jaExiste = _aparelhosEncontrados.any((item) => item.id == id);
            if (!jaExiste) {
              _aparelhosEncontrados.add(
                _AparelhoEncontrado(id: id, nome: nome),
              );
            }
          });
          _atualizarModalBusca?.call();
        },
        onEndpointLost: (id) {
          setState(() {
            _aparelhosEncontrados.removeWhere((item) => item.id == id);
          });
          _atualizarModalBusca?.call();
        },
      );

      if (!mounted) return;
      setState(() {
        _procurando = iniciado;
      });
    } catch (erro) {
      _definirErro('Não foi possível procurar aparelhos: $erro');
    }
  }

  Future<void> _alternarBuscaBle() async {
    setState(() {
      _mensagemErro = null;
    });

    if (_procurandoBle) {
      await UniversalBle.stopScan();
      if (!mounted) return;
      setState(() {
        _procurandoBle = false;
      });
      return;
    }

    if (!await _pedirPermissoes()) return;

    try {
      await UniversalBle.requestPermissions();
      if (!mounted) return;

      setState(() {
        _notebooksEncontrados.clear();
        _procurandoBle = true;
      });

      await UniversalBle.startScan(
        scanFilter: ScanFilter(withServices: [_serviceUuid]),
      );
    } catch (erro) {
      if (mounted) {
        setState(() {
          _procurandoBle = false;
        });
      }
      _definirErro('Não foi possível procurar notebooks BLE: $erro');
    }
  }

  Future<void> _conectarBle(BleDevice notebook) async {
    if (_conectandoBle) return;

    try {
      setState(() {
        _conectandoBle = true;
        _mensagemErro = null;
      });

      if (_procurandoBle) {
        await UniversalBle.stopScan();
      }

      await UniversalBle.connect(notebook.deviceId);
      await UniversalBle.discoverServices(
        notebook.deviceId,
        withDescriptors: true,
      );
      await UniversalBle.subscribeNotifications(
        notebook.deviceId,
        _serviceUuid,
        _notifyCharacteristicUuid,
      );

      if (!mounted) return;
      setState(() {
        _procurandoBle = false;
        _notebooksEncontrados.remove(notebook.deviceId);
        _notebooksConectados[notebook.deviceId] = notebook;
        _conversaSelecionadaId = _chaveNotebookCentral(notebook.deviceId);
      });
      unawaited(
        _reenviarMensagensPendentes(_chaveNotebookCentral(notebook.deviceId)),
      );
      _atualizarModalBusca?.call();
      _mostrarMensagem('Notebook conectado.');
    } catch (erro) {
      _definirErro('Falha ao conectar no notebook. Busque novamente. $erro');
    } finally {
      if (mounted) {
        setState(() {
          _conectandoBle = false;
        });
      }
    }
  }

  Future<void> _conectar(_AparelhoEncontrado aparelho) async {
    if (_conectando) return;

    try {
      setState(() {
        _conectando = true;
        _mensagemErro = null;
      });

      if (_procurando) {
        await Nearby().stopDiscovery();
      }

      if (_anunciando) {
        await Nearby().stopAdvertising();
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _procurando = false;
        _anunciando = false;
      });

      await Nearby().requestConnection(
        _nomeUsuario,
        aparelho.id,
        onConnectionInitiated: _aoIniciarConexao,
        onConnectionResult: _aoResultadoConexao,
        onDisconnected: _aoDesconectar,
      );
    } catch (erro) {
      _definirErro(
        'Falha ao solicitar conexão. Toque em Buscar aparelhos e tente novamente. $erro',
      );
    } finally {
      if (mounted) {
        setState(() {
          _conectando = false;
        });
      }
    }
  }

  void _aoIniciarConexao(String id, ConnectionInfo info) {
    if (!mounted) return;

    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Conectar com ${info.endpointName}?'),
          content: Text('Código de confirmação: ${info.authenticationToken}'),
          actions: [
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await Nearby().rejectConnection(id);
              },
              child: const Text('Recusar'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                _aceitarConexao(id, info);
              },
              child: const Text('Aceitar'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _aceitarConexao(String id, ConnectionInfo info) async {
    setState(() {
      _aparelhosConectados[id] = info;
      _aparelhosEncontrados.removeWhere((item) => item.id == id);
      _conversaSelecionadaId = _chaveCelular(id);
    });
    _marcarConversaComoAberta(_chaveCelular(id));
    _atualizarModalBusca?.call();

    await Nearby().acceptConnection(
      id,
      onPayLoadRecieved: (endpointId, payload) {
        if (payload.type != PayloadType.BYTES || payload.bytes == null) return;

        final texto = utf8.decode(payload.bytes!);
        final nome =
            _aparelhosConectados[endpointId]?.endpointName ?? 'Aparelho';
        final conversaId = _chaveCelular(endpointId);
        _processarPacotesRecebidos(texto, conversaId, nome);
      },
      onPayloadTransferUpdate: (_, update) {},
    );
  }

  void _aoResultadoConexao(String id, Status status) {
    if (status == Status.CONNECTED) {
      setState(() {
        _conectando = false;
      });
      unawaited(_reenviarMensagensPendentes(_chaveCelular(id)));
      _mostrarMensagem('Conectado.');
      return;
    }

    if (status == Status.REJECTED) {
      setState(() {
        _aparelhosConectados.remove(id);
        if (_conversaSelecionadaId == _chaveCelular(id)) {
          _conversaSelecionadaId = null;
        }
        _conectando = false;
      });
      _mostrarMensagem('Conexão recusada.');
      return;
    }

    if (status == Status.ERROR) {
      setState(() {
        _aparelhosConectados.remove(id);
        if (_conversaSelecionadaId == _chaveCelular(id)) {
          _conversaSelecionadaId = null;
        }
        _conectando = false;
      });
      _mostrarMensagem('Erro ao conectar.');
    }
  }

  void _aoDesconectar(String id) {
    final nome = _aparelhosConectados[id]?.endpointName ?? 'Aparelho';

    setState(() {
      _aparelhosConectados.remove(id);
      if (_conversaSelecionadaId == _chaveCelular(id)) {
        _conversaSelecionadaId = null;
      }
    });

    _mostrarMensagem('$nome desconectou.');
  }

  Future<void> _enviarMensagem() async {
    final texto = _mensagemController.text.trim();
    final conversa = _conversaSelecionada;
    if (texto.isEmpty || conversa == null) return;

    final mensagemId = _novoIdMensagem();
    setState(() {
      _mensagens.add(
        _MensagemChat(
          id: mensagemId,
          conversaId: conversa.id,
          texto: texto,
          remetente: _nomeUsuario,
          enviadaPorMim: true,
          status: MessageStatus.digitada,
        ),
      );
      _mensagemController.clear();
    });
    unawaited(_persistirMensagens());

    final bytes = _codificarMensagem(mensagemId, texto);

    try {
      switch (conversa.tipo) {
        case _TipoConversa.celular:
          await Nearby().sendBytesPayload(conversa.deviceId, bytes);
        case _TipoConversa.notebookCentral:
          await UniversalBle.write(
            conversa.deviceId,
            _serviceUuid,
            _messageCharacteristicUuid,
            bytes,
          );
        case _TipoConversa.notebookPeripheral:
          await UniversalBlePeripheral.updateCharacteristicValue(
            characteristicId: _notifyCharacteristicUuid,
            value: bytes,
          );
      }
      _atualizarStatusMensagem(mensagemId, MessageStatus.recebida);
    } catch (erro) {
      _definirErro('Não foi possível enviar a mensagem: $erro');
    }
  }

  void _atualizarStatusMensagem(String mensagemId, MessageStatus status) {
    if (!mounted) return;
    final index = _mensagens.indexWhere(
      (mensagem) => mensagem.id == mensagemId,
    );
    if (index == -1) return;

    setState(() {
      _mensagens[index] = _mensagens[index].copyWith(status: status);
    });
    unawaited(_persistirMensagens());
  }

  void _adicionarMensagemRecebidaAoHistorico(_MensagemChat mensagem) {
    setState(() {
      _mensagens.add(mensagem);
    });
    unawaited(_persistirMensagens());
  }

  void _adicionarMensagemBle(String deviceId, Uint8List value) {
    final texto = utf8.decode(value, allowMalformed: true).trim();
    if (texto.isEmpty || !mounted) return;

    final nome =
        _notebooksConectados[deviceId]?.name ??
        _clientesBlePeripheral[deviceId] ??
        'Notebook';
    final conversaId = _notebooksConectados.containsKey(deviceId)
        ? _chaveNotebookCentral(deviceId)
        : _chaveNotebookPeripheral(deviceId);
    _processarPacotesRecebidos(texto, conversaId, nome);
  }

  void _marcarConversaComoAberta(String conversaId) {
    if (!mounted || !_conversaEstaAberta(conversaId)) return;
    var alterou = false;

    for (var i = 0; i < _mensagens.length; i++) {
      final mensagem = _mensagens[i];
      if (mensagem.conversaId == conversaId &&
          !mensagem.enviadaPorMim &&
          mensagem.status != MessageStatus.aberta) {
        _mensagens[i] = mensagem.copyWith(status: MessageStatus.aberta);
        alterou = true;
        unawaited(_enviarConfirmacaoAbertura(conversaId, mensagem.id));
      }
    }

    if (alterou) {
      setState(() {});
      unawaited(_persistirMensagens());
    }
  }

  bool _conversaEstaAberta(String conversaId) {
    return _appEmPrimeiroPlano && _conversaSelecionadaId == conversaId;
  }

  Future<void> _enviarConfirmacaoAbertura(
    String conversaId,
    String mensagemId,
  ) async {
    final conversa = _conversaPorId(conversaId);
    if (conversa == null) return;

    final bytes = _codificarConfirmacaoAbertura(mensagemId);
    switch (conversa.tipo) {
      case _TipoConversa.celular:
        await Nearby().sendBytesPayload(conversa.deviceId, bytes);
      case _TipoConversa.notebookCentral:
        await UniversalBle.write(
          conversa.deviceId,
          _serviceUuid,
          _messageCharacteristicUuid,
          bytes,
        );
      case _TipoConversa.notebookPeripheral:
        await UniversalBlePeripheral.updateCharacteristicValue(
          characteristicId: _notifyCharacteristicUuid,
          value: bytes,
        );
    }
  }

  Future<void> _reenviarMensagensPendentes(String conversaId) async {
    final conversa = _conversaPorId(conversaId);
    if (conversa == null) return;

    final pendentes = _mensagens
        .where(
          (mensagem) =>
              mensagem.conversaId == conversaId &&
              mensagem.enviadaPorMim &&
              mensagem.status == MessageStatus.digitada,
        )
        .toList();
    if (pendentes.isEmpty) return;

    final bytes = _codificarLoteMensagens(pendentes);
    switch (conversa.tipo) {
      case _TipoConversa.celular:
        await Nearby().sendBytesPayload(conversa.deviceId, bytes);
      case _TipoConversa.notebookCentral:
        await UniversalBle.write(
          conversa.deviceId,
          _serviceUuid,
          _messageCharacteristicUuid,
          bytes,
        );
      case _TipoConversa.notebookPeripheral:
        await UniversalBlePeripheral.updateCharacteristicValue(
          characteristicId: _notifyCharacteristicUuid,
          value: bytes,
        );
    }

    for (final mensagem in pendentes) {
      _atualizarStatusMensagem(mensagem.id, MessageStatus.recebida);
    }
  }

  String _chaveCelular(String id) => 'celular:$id';
  String _chaveNotebookCentral(String id) => 'notebook-central:$id';
  String _chaveNotebookPeripheral(String id) => 'notebook-peripheral:$id';

  List<_Conversa> get _conversas {
    return [
      for (final entry in _aparelhosConectados.entries)
        _Conversa(
          id: _chaveCelular(entry.key),
          deviceId: entry.key,
          nome: entry.value.endpointName,
          subtitulo: 'Celular',
          tipo: _TipoConversa.celular,
          icone: Icons.smartphone,
        ),
      for (final entry in _notebooksConectados.entries)
        _Conversa(
          id: _chaveNotebookCentral(entry.key),
          deviceId: entry.key,
          nome: entry.value.name?.isNotEmpty == true
              ? entry.value.name!
              : 'Notebook BLE',
          subtitulo: 'Notebook',
          tipo: _TipoConversa.notebookCentral,
          icone: Icons.computer,
        ),
      for (final entry in _clientesBlePeripheral.entries)
        _Conversa(
          id: _chaveNotebookPeripheral(entry.key),
          deviceId: entry.key,
          nome: 'Notebook BLE',
          subtitulo: 'Notebook',
          tipo: _TipoConversa.notebookPeripheral,
          icone: Icons.computer,
        ),
    ];
  }

  _Conversa? get _conversaSelecionada {
    final id = _conversaSelecionadaId;
    if (id == null) return null;
    return _conversaPorId(id);
  }

  _Conversa? _conversaPorId(String id) {
    for (final conversa in _conversas) {
      if (conversa.id == id) return conversa;
    }
    return null;
  }

  List<_MensagemChat> _mensagensDaConversa(String conversaId) {
    return _mensagens
        .where((mensagem) => mensagem.conversaId == conversaId)
        .toList();
  }

  Future<void> _abrirBuscaCelulares() async {
    if (!_procurando) {
      await _alternarBusca();
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            _atualizarModalBusca = () => setModalState(() {});
            return _ModalBuscaCelulares(
              aparelhos: _aparelhosEncontrados,
              conectando: _conectando,
              onConectar: (aparelho) async {
                await _conectar(aparelho);
                if (context.mounted && Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
            );
          },
        );
      },
    );

    _atualizarModalBusca = null;
    if (_procurando) {
      await Nearby().stopDiscovery();
      if (mounted) {
        setState(() => _procurando = false);
      }
    }
    if (mounted) {
      await _garantirDisponibilidade();
    }
  }

  Future<void> _abrirBuscaNotebooks() async {
    if (!_procurandoBle) {
      await _alternarBuscaBle();
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            _atualizarModalBusca = () => setModalState(() {});
            return _ModalBuscaNotebooks(
              notebooks: _notebooksEncontrados.values.toList(),
              conectando: _conectandoBle,
              onConectar: (notebook) async {
                await _conectarBle(notebook);
                if (context.mounted && Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              },
            );
          },
        );
      },
    );

    _atualizarModalBusca = null;
    if (_procurandoBle) {
      await UniversalBle.stopScan();
      if (mounted) {
        setState(() => _procurandoBle = false);
      }
    }
    if (mounted) {
      await _garantirDisponibilidade();
    }
  }

  void _definirErro(String mensagem) {
    if (!mounted) return;
    setState(() {
      _mensagemErro = mensagem;
    });
  }

  void _mostrarMensagem(String mensagem) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(mensagem)));
  }

  @override
  Widget build(BuildContext context) {
    final conversa = _conversaSelecionada;

    return Scaffold(
      appBar: AppBar(
        leading: conversa == null
            ? null
            : IconButton(
                tooltip: 'Voltar',
                onPressed: () => setState(() => _conversaSelecionadaId = null),
                icon: const Icon(Icons.arrow_back),
              ),
        title: Text(conversa?.nome ?? 'Conexão Bluetooth'),
        actions: [
          PopupMenuButton<_AcaoMenu>(
            onSelected: (acao) {
              switch (acao) {
                case _AcaoMenu.editarNome:
                  _abrirEdicaoNome();
                case _AcaoMenu.buscarCelulares:
                  _abrirBuscaCelulares();
                case _AcaoMenu.buscarNotebooks:
                  _abrirBuscaNotebooks();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: _AcaoMenu.editarNome,
                child: ListTile(
                  leading: Icon(Icons.edit),
                  title: Text('Nome do aparelho'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _AcaoMenu.buscarCelulares,
                child: ListTile(
                  leading: Icon(Icons.smartphone),
                  title: Text('Buscar celulares'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _AcaoMenu.buscarNotebooks,
                child: ListTile(
                  leading: Icon(Icons.computer),
                  title: Text('Buscar notebooks'),
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
            if (_mensagemErro != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  _mensagemErro!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: conversa == null
                  ? _ListaConversas(
                      conversas: _conversas,
                      mensagens: _mensagens,
                      nomeUsuario: _nomeUsuario,
                      disponivel: _anunciando || _anunciandoBle,
                      nearbyDisponivel: _anunciando,
                      bleDisponivel: _anunciandoBle,
                      onSelecionar: (conversa) {
                        setState(() => _conversaSelecionadaId = conversa.id);
                        _marcarConversaComoAberta(conversa.id);
                      },
                    )
                  : _Chat(
                      mensagens: _mensagensDaConversa(conversa.id),
                      controller: _mensagemController,
                      conectado: true,
                      onEnviar: _enviarMensagem,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
