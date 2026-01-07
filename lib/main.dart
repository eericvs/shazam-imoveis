import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

// --- CONFIGURAÇÃO ---
// ⚠️ Troque pelo seu IP local ou pelo link do Render (https://shazam-api.onrender.com)
const String BASE_URL = "http://192.168.0.18:8000";

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializa a câmera
  final cameras = await availableCameras();
  final firstCamera = cameras.first;

  runApp(
    MaterialApp(
      home: TirarFotoScreen(camera: firstCamera),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.blue),
    ),
  );
}

// --- TELA PRINCIPAL (CÂMERA + RADAR AUTOMÁTICO) ---
class TirarFotoScreen extends StatefulWidget {
  final CameraDescription camera;
  const TirarFotoScreen({super.key, required this.camera});

  @override
  TirarFotoScreenState createState() => TirarFotoScreenState();
}

class TirarFotoScreenState extends State<TirarFotoScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;

  // VARIÁVEIS DO RADAR AUTOMÁTICO
  List<dynamic> _listaImoveisCache = []; // Guarda os imóveis baixados
  Map<String, dynamic>? _imovelDetectado; // O imóvel que aparece no cartão
  double? _direcaoReal = 0.0; // Para onde o celular aponta (Azimute)
  bool _modoRadarAtivo = true;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(widget.camera, ResolutionPreset.medium);
    _initializeControllerFuture = _controller.initialize();

    // 1. LIGA A BÚSSOLA E O MONITORAMENTO
    FlutterCompass.events?.listen((event) {
      if (mounted) {
        setState(() {
          _direcaoReal = event.heading;

          // A MÁGICA: Se tiver imóveis na memória, verifica se estamos apontando para um deles
          if (_modoRadarAtivo &&
              _listaImoveisCache.isNotEmpty &&
              _direcaoReal != null) {
            _verificarMira(_direcaoReal!);
          }
        });
      }
    });

    // 2. CARREGA OS DADOS DO SERVIDOR SILENCIOSAMENTE
    _atualizarCacheDeImoveis();
  }

  // Busca os imóveis ao redor e guarda na memória do celular
  Future<void> _atualizarCacheDeImoveis() async {
    try {
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      var uri = Uri.parse(
        "$BASE_URL/api/v1/imoveis/proximos?lat=${pos.latitude}&lon=${pos.longitude}",
      );
      var response = await http.get(uri);

      if (response.statusCode == 200) {
        setState(() {
          _listaImoveisCache = json.decode(response.body);
        });
        print(
          ">>> RADAR: Cache atualizado. ${_listaImoveisCache.length} imóveis na memória.",
        );
      }
    } catch (e) {
      print(">>> RADAR ERRO: $e");
    }
  }

  // A Lógica Matemática: Compara a direção do celular com a do prédio
  void _verificarMira(double headingCelular) {
    Map<String, dynamic>? alvoEncontrado;
    double menorDiferenca = 1000.0;
    double campoDeVisao = 15.0; // Graus de tolerância (o cone de visão)

    for (var imovel in _listaImoveisCache) {
      if (imovel['azimute_imovel'] != null) {
        double azimutePredio = double.parse(
          imovel['azimute_imovel'].toString(),
        );

        // Calcula a diferença angular (corrigindo o problema do 360 vs 0)
        double diff = (headingCelular - azimutePredio).abs();
        if (diff > 180) diff = 360 - diff;

        // Se estiver mirando perto E for o mais centralizado
        if (diff < campoDeVisao && diff < menorDiferenca) {
          menorDiferenca = diff;
          alvoEncontrado = imovel;
        }
      }
    }

    // Só atualiza a tela se mudou o alvo (para não piscar)
    if (_imovelDetectado != alvoEncontrado) {
      setState(() {
        _imovelDetectado = alvoEncontrado;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // Envia foto para o servidor
  Future<void> _capturarEEnviar() async {
    try {
      await _initializeControllerFuture;
      final image = await _controller.takePicture();
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      double azimute = _direcaoReal ?? 0.0;
      if (azimute < 0) azimute += 360;

      var request = http.MultipartRequest(
        'POST',
        Uri.parse("$BASE_URL/api/v1/imoveis"),
      );

      request.fields['titulo'] = "Imóvel Capturado";
      request.fields['latitude'] = pos.latitude.toString();
      request.fields['longitude'] = pos.longitude.toString();
      request.fields['azimute'] = azimute.toString();
      request.files.add(await http.MultipartFile.fromPath('foto', image.path));

      var response = await request.send();
      if (response.statusCode == 200) {
        _mostrarAlerta(
          "Sucesso",
          "Imóvel salvo! O Radar vai detectá-lo em breve.",
        );
        _atualizarCacheDeImoveis(); // Atualiza a lista para achar o novo imóvel
      } else {
        _mostrarAlerta("Erro", "Servidor rejeitou: ${response.statusCode}");
      }
    } catch (e) {
      _mostrarAlerta("Erro Crítico", "$e");
    }
  }

  void _abrirMapa() async {
    Position pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            MapaScreen(latitude: pos.latitude, longitude: pos.longitude),
      ),
    );
  }

  void _mostrarAlerta(String titulo, String mensagem) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: Text(mensagem),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("OK"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<void>(
        future: _initializeControllerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Stack(
              children: [
                // 1. Câmera Fundo
                SizedBox(
                  width: double.infinity,
                  height: double.infinity,
                  child: CameraPreview(_controller),
                ),

                // 2. Dados da Bússola (Topo Direito)
                Positioned(
                  top: 50,
                  right: 20,
                  child: Column(
                    children: [
                      Transform.rotate(
                        angle: ((_direcaoReal ?? 0) * (math.pi / 180) * -1),
                        child: const Icon(
                          Icons.navigation,
                          size: 50,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        "${_direcaoReal?.toStringAsFixed(0)}°",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      Text(
                        "Cache: ${_listaImoveisCache.length}",
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),

                // 3. MIRA CENTRAL (Crosshair)
                // Ajuda a saber onde apontar
                Center(
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.white.withOpacity(0.6),
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Center(
                      child: Container(width: 4, height: 4, color: Colors.red),
                    ),
                  ),
                ),

                // 4. CARTÃO DO IMÓVEL (Aparece Automaticamente)
                if (_imovelDetectado != null)
                  Positioned(
                    top: 150,
                    left: 20,
                    right: 20,
                    child: Card(
                      color: Colors.white.withOpacity(0.95),
                      elevation: 8,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(15),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              "🎯 LOCALIZADO",
                              style: TextStyle(
                                color: Colors.green,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              _imovelDetectado!['titulo'] ?? "Imóvel",
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Divider(),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                Column(
                                  children: [
                                    const Icon(
                                      Icons.directions_walk,
                                      color: Colors.grey,
                                    ),
                                    Text(
                                      "${_imovelDetectado!['distancia_metros']}m",
                                    ),
                                  ],
                                ),
                                Column(
                                  children: [
                                    const Icon(
                                      Icons.explore,
                                      color: Colors.grey,
                                    ),
                                    Text(
                                      "${_imovelDetectado!['azimute_imovel']}°",
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                // 5. Botões (Rodapé)
                Positioned(
                  bottom: 30,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FloatingActionButton(
                          heroTag: "btnMapa",
                          onPressed: _abrirMapa,
                          backgroundColor: Colors.green,
                          child: const Icon(Icons.map),
                        ),
                        const SizedBox(width: 20),
                        // Botão sync para forçar atualização da lista se você andou muito
                        FloatingActionButton(
                          heroTag: "btnSync",
                          onPressed: _atualizarCacheDeImoveis,
                          backgroundColor: Colors.blue,
                          child: const Icon(Icons.sync),
                        ),
                        const SizedBox(width: 20),
                        FloatingActionButton(
                          heroTag: "btnCamera",
                          onPressed: _capturarEEnviar,
                          backgroundColor: Colors.redAccent,
                          child: const Icon(Icons.camera_alt),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          } else {
            return const Center(child: CircularProgressIndicator());
          }
        },
      ),
    );
  }
}

// --- TELA MAPA (Mantendo a correção da Latitude/Longitude) ---
class MapaScreen extends StatefulWidget {
  final double latitude;
  final double longitude;

  const MapaScreen({
    super.key,
    required this.latitude,
    required this.longitude,
  });

  @override
  State<MapaScreen> createState() => _MapaScreenState();
}

class _MapaScreenState extends State<MapaScreen> {
  List<Marker> _marcadores = [];

  @override
  void initState() {
    super.initState();
    _marcadores.add(
      Marker(
        point: LatLng(widget.latitude, widget.longitude),
        width: 80,
        height: 80,
        child: const Icon(
          Icons.person_pin_circle,
          color: Colors.blue,
          size: 40,
        ),
      ),
    );
    _carregarImoveisNoMapa();
  }

  Future<void> _carregarImoveisNoMapa() async {
    try {
      print(">>> MAPA: Buscando imóveis...");
      var uri = Uri.parse(
        "$BASE_URL/api/v1/imoveis/proximos?lat=${widget.latitude}&lon=${widget.longitude}",
      );
      var response = await http.get(uri);

      if (response.statusCode == 200) {
        var lista = json.decode(response.body) as List;

        setState(() {
          for (var imovel in lista) {
            // Conversão segura de dados
            double lat = double.tryParse(imovel['latitude'].toString()) ?? 0.0;
            double lon = double.tryParse(imovel['longitude'].toString()) ?? 0.0;

            if (lat != 0.0 && lon != 0.0) {
              _marcadores.add(
                Marker(
                  point: LatLng(lat, lon),
                  width: 80,
                  height: 80,
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(2),
                        color: Colors.white,
                        child: Text(
                          imovel['titulo'] ?? "Imóvel",
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.location_pin,
                        color: Colors.red,
                        size: 40,
                      ),
                    ],
                  ),
                ),
              );
            }
          }
        });
      }
    } catch (e) {
      print(">>> MAPA ERRO: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Mapa Radar")),
      body: FlutterMap(
        options: MapOptions(
          initialCenter: LatLng(widget.latitude, widget.longitude),
          initialZoom: 16.0,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'dev.eric.shazam',
          ),
          MarkerLayer(markers: _marcadores),
        ],
      ),
    );
  }
}
