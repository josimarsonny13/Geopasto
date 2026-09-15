import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const GeopastoApp());

class GeopastoApp extends StatelessWidget {
  const GeopastoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Geopasto',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF237A3B)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF1F7F1),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
        ),
      ),
      home: const GeopastoHome(),
    );
  }
}

enum AreaUnit { squareMeter, hectare, paulista, mineiroGoiano, baiano, norte }

extension AreaUnitView on AreaUnit {
  String get title => switch (this) {
        AreaUnit.squareMeter => 'Metros quadrados (m²)',
        AreaUnit.hectare => 'Hectares (ha)',
        AreaUnit.paulista => 'Alqueire paulista — SP/PR',
        AreaUnit.mineiroGoiano => 'Alqueire mineiro/goiano — MG/GO',
        AreaUnit.baiano => 'Alqueire baiano — BA',
        AreaUnit.norte => 'Alqueire do Norte',
      };

  String format(double squareMeters) {
    final (value, suffix, decimals) = switch (this) {
      AreaUnit.squareMeter => (squareMeters, 'm²', 0),
      AreaUnit.hectare => (squareMeters / 10000, 'ha', 2),
      AreaUnit.paulista => (squareMeters / 24200, 'alq. paulista', 2),
      AreaUnit.mineiroGoiano => (squareMeters / 48400, 'alq. mineiro/goiano', 2),
      AreaUnit.baiano => (squareMeters / 96800, 'alq. baiano', 2),
      AreaUnit.norte => (squareMeters / 27225, 'alq. do Norte', 2),
    };
    return '${value.toStringAsFixed(decimals).replaceAll('.', ',')} $suffix';
  }
}

class Paddock {
  Paddock({required this.name, required this.points, this.biomass = 0});
  final String name;
  final List<LatLng> points;
  final double biomass;

  double get areaM2 => polygonArea(points);

  Map<String, dynamic> toJson() => {
        'name': name,
        'biomass': biomass,
        'points': points.map((p) => [p.latitude, p.longitude]).toList(),
      };

  factory Paddock.fromJson(Map<String, dynamic> json) => Paddock(
        name: json['name'] as String,
        biomass: (json['biomass'] as num?)?.toDouble() ?? 0,
        points: (json['points'] as List)
            .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
            .toList(),
      );
}

double polygonArea(List<LatLng> points) {
  if (points.length < 3) return 0;
  const radius = 6378137.0;
  final meanLat = points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
  final cosLat = math.cos(meanLat * math.pi / 180);
  double sum = 0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i];
    final b = points[(i + 1) % points.length];
    final ax = radius * a.longitude * math.pi / 180 * cosLat;
    final ay = radius * a.latitude * math.pi / 180;
    final bx = radius * b.longitude * math.pi / 180 * cosLat;
    final by = radius * b.latitude * math.pi / 180;
    sum += ax * by - bx * ay;
  }
  return sum.abs() / 2;
}

bool pointInside(LatLng point, List<LatLng> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (int i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final xi = polygon[i].longitude, yi = polygon[i].latitude;
    final xj = polygon[j].longitude, yj = polygon[j].latitude;
    final intersects = ((yi > point.latitude) != (yj > point.latitude)) &&
        (point.longitude < (xj - xi) * (point.latitude - yi) / ((yj - yi).abs() < 1e-12 ? 1e-12 : yj - yi) + xi);
    if (intersects) inside = !inside;
  }
  return inside;
}

class GeopastoHome extends StatefulWidget {
  const GeopastoHome({super.key});
  @override
  State<GeopastoHome> createState() => _GeopastoHomeState();
}

class _GeopastoHomeState extends State<GeopastoHome> {
  final mapController = MapController();
  final propertyName = TextEditingController();
  final ownerName = TextEditingController();
  final phone = TextEditingController();
  final totalArea = TextEditingController();
  final draftName = TextEditingController();
  final List<Paddock> paddocks = [];
  final List<LatLng> propertyBoundary = [];
  final List<LatLng> draft = [];
  StreamSubscription<Position>? locationStream;
  Position? position;
  AreaUnit unit = AreaUnit.hectare;
  int page = 0;
  bool loading = true;
  bool drawingProperty = false;
  bool walking = false;

  double get pastureAreaM2 => paddocks.fold(0, (sum, p) => sum + p.areaM2);
  double get totalAreaM2 => (double.tryParse(totalArea.text.replaceAll(',', '.')) ?? 0) * 10000;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    locationStream?.cancel();
    for (final c in [propertyName, ownerName, phone, totalArea, draftName]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    propertyName.text = prefs.getString('propertyName') ?? '';
    ownerName.text = prefs.getString('ownerName') ?? '';
    phone.text = prefs.getString('phone') ?? '';
    totalArea.text = prefs.getString('totalArea') ?? '';
    unit = AreaUnit.values[prefs.getInt('unit') ?? 1];
    final boundary = prefs.getString('boundary');
    if (boundary != null) {
      propertyBoundary.addAll((jsonDecode(boundary) as List).map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble())));
    }
    final saved = prefs.getString('paddocks');
    if (saved != null) {
      paddocks.addAll((jsonDecode(saved) as List).map((p) => Paddock.fromJson(p)));
    }
    setState(() => loading = false);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('propertyName', propertyName.text.trim());
    await prefs.setString('ownerName', ownerName.text.trim());
    await prefs.setString('phone', phone.text.trim());
    await prefs.setString('totalArea', totalArea.text.trim());
    await prefs.setInt('unit', unit.index);
    await prefs.setString('boundary', jsonEncode(propertyBoundary.map((p) => [p.latitude, p.longitude]).toList()));
    await prefs.setString('paddocks', jsonEncode(paddocks.map((p) => p.toJson()).toList()));
  }

  Future<void> _locate() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Autorize a localização para visualizar sua posição.')));
      return;
    }
    final current = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    setState(() => position = current);
    mapController.move(LatLng(current.latitude, current.longitude), 17);
  }

  Future<void> _toggleWalk() async {
    if (walking) {
      await locationStream?.cancel();
      setState(() => walking = false);
      return;
    }
    await _locate();
    if (position == null) return;
    setState(() {
      walking = true;
      draft.clear();
    });
    locationStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 3),
    ).listen((p) {
      if (!mounted) return;
      setState(() {
        position = p;
        draft.add(LatLng(p.latitude, p.longitude));
      });
    });
  }

  void _finishDrawing() {
    if (draft.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Marque pelo menos três pontos.')));
      return;
    }
    if (drawingProperty) {
      setState(() {
        propertyBoundary
          ..clear()
          ..addAll(draft);
        draft.clear();
        drawingProperty = false;
      });
    } else {
      final name = draftName.text.trim().isEmpty ? 'P${paddocks.length + 1}' : draftName.text.trim();
      setState(() {
        paddocks.add(Paddock(name: name, points: List.of(draft)));
        draft.clear();
        draftName.clear();
      });
    }
    _save();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final registered = propertyName.text.trim().isNotEmpty;
    if (!registered) return _registration(firstAccess: true);
    final pages = [_dashboard(), _map(), _paddockList(), _biomass(), _registration(firstAccess: false)];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF237A3B),
        foregroundColor: Colors.white,
        title: Row(children: [Image.asset('assets/images/geopasto_icon.png', width: 38, height: 38), const SizedBox(width: 10), const Text('Geopasto')]),
      ),
      body: pages[page],
      bottomNavigationBar: NavigationBar(
        selectedIndex: page,
        onDestinationSelected: (value) => setState(() => page = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Início'),
          NavigationDestination(icon: Icon(Icons.map_outlined), selectedIcon: Icon(Icons.map), label: 'Mapa'),
          NavigationDestination(icon: Icon(Icons.grid_view_outlined), label: 'Piquetes'),
          NavigationDestination(icon: Icon(Icons.grass_outlined), label: 'Massa'),
          NavigationDestination(icon: Icon(Icons.person_outline), label: 'Cadastro'),
        ],
      ),
    );
  }

  Widget _registration({required bool firstAccess}) => Scaffold(
        appBar: firstAccess ? AppBar(title: const Text('Cadastro da propriedade'), backgroundColor: const Color(0xFF237A3B), foregroundColor: Colors.white) : null,
        body: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            if (firstAccess) ...[
              Center(child: ClipRRect(borderRadius: BorderRadius.circular(28), child: Image.asset('assets/images/geopasto_icon.png', width: 126, height: 126))),
              const SizedBox(height: 12),
              const Text('Bem-vindo ao Geopasto', textAlign: TextAlign.center, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
            ],
            TextField(controller: propertyName, decoration: const InputDecoration(labelText: 'Nome da propriedade', prefixIcon: Icon(Icons.agriculture))),
            const SizedBox(height: 12),
            TextField(controller: totalArea, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Área total da propriedade (ha)', prefixIcon: Icon(Icons.square_foot))),
            const SizedBox(height: 12),
            TextField(controller: ownerName, decoration: const InputDecoration(labelText: 'Nome do proprietário', prefixIcon: Icon(Icons.person))),
            const SizedBox(height: 12),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Telefone', prefixIcon: Icon(Icons.phone))),
            const SizedBox(height: 12),
            DropdownButtonFormField<AreaUnit>(value: unit, decoration: const InputDecoration(labelText: 'Unidade para exibir áreas'), items: AreaUnit.values.map((u) => DropdownMenuItem(value: u, child: Text(u.title))).toList(), onChanged: (u) => setState(() => unit = u!)),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () async {
                if (propertyName.text.trim().isEmpty || totalAreaM2 <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Informe o nome e a área total da propriedade.')));
                  return;
                }
                await _save();
                if (mounted) setState(() => page = 0);
              },
              icon: const Icon(Icons.save),
              label: Text(firstAccess ? 'Cadastrar propriedade' : 'Salvar alterações'),
            ),
          ],
        ),
      );

  Widget _dashboard() {
    final percent = totalAreaM2 <= 0 ? 0.0 : (pastureAreaM2 / totalAreaM2 * 100).clamp(0, 999).toDouble();
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(propertyName.text, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
      Text('Proprietário: ${ownerName.text}'),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: _metric('Área total', unit.format(totalAreaM2), Icons.landscape)),
        const SizedBox(width: 10),
        Expanded(child: _metric('Área de pastagem', unit.format(pastureAreaM2), Icons.grass)),
      ]),
      const SizedBox(height: 10),
      _metric('Uso da propriedade', '${percent.toStringAsFixed(1).replaceAll('.', ',')}% em ${paddocks.length} piquete(s)', Icons.pie_chart),
      const SizedBox(height: 16),
      FilledButton.icon(onPressed: () => setState(() => page = 1), icon: const Icon(Icons.my_location), label: const Text('Abrir mapa georreferenciado')),
      const SizedBox(height: 16),
      const Text('Imagem gratuita para monitoramento', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
      const SizedBox(height: 8),
      ClipRRect(borderRadius: BorderRadius.circular(18), child: Stack(alignment: Alignment.bottomRight, children: [Image.asset('assets/images/sentinel_demo.jpg', height: 190, width: double.infinity, fit: BoxFit.cover), Container(margin: const EdgeInsets.all(8), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), color: Colors.black87, child: const Text('Sentinel-2 · Copernicus', style: TextStyle(color: Colors.white))) ])),
    ]);
  }

  Widget _metric(String label, String value, IconData icon) => Card(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [CircleAvatar(backgroundColor: const Color(0xFFDDF0E1), child: Icon(icon, color: const Color(0xFF237A3B))), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Colors.black54)), Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))]))])));

  Widget _map() {
    final current = position == null ? const LatLng(-22.98, -49.87) : LatLng(position!.latitude, position!.longitude);
    final currentPaddock = position == null ? null : paddocks.cast<Paddock?>().firstWhere((p) => p != null && pointInside(current, p.points), orElse: () => null);
    final insideProperty = position != null && pointInside(current, propertyBoundary);
    return Stack(children: [
      FlutterMap(
        mapController: mapController,
        options: MapOptions(
          initialCenter: current,
          initialZoom: 15,
          onTap: (_, point) {
            if (!walking) setState(() => draft.add(point));
          },
        ),
        children: [
          TileLayer(urlTemplate: 'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2020_3857/default/g/{z}/{y}/{x}.jpg', userAgentPackageName: 'com.geopasto.app'),
          PolygonLayer(polygons: [
            if (propertyBoundary.length >= 3) Polygon(points: propertyBoundary, color: Colors.transparent, borderColor: Colors.white, borderStrokeWidth: 4),
            ...paddocks.asMap().entries.map((e) => Polygon(points: e.value.points, color: [Colors.green, Colors.lightGreen, Colors.amber, Colors.teal, Colors.orange][e.key % 5].withOpacity(.32), borderColor: Colors.white, borderStrokeWidth: 2, label: '${e.value.name}\n${unit.format(e.value.areaM2)}', labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
            if (draft.length >= 3) Polygon(points: draft, color: Colors.blue.withOpacity(.25), borderColor: Colors.blueAccent, borderStrokeWidth: 3),
          ]),
          PolylineLayer(polylines: [if (draft.length >= 2) Polyline(points: draft, color: Colors.blueAccent, strokeWidth: 4)]),
          MarkerLayer(markers: [
            if (position != null) Marker(point: current, width: 54, height: 54, child: const Icon(Icons.my_location, color: Colors.blue, size: 42)),
          ]),
          RichAttributionWidget(attributions: const [TextSourceAttribution('Sentinel-2 cloudless · EOX/Copernicus')]),
        ],
      ),
      Positioned(top: 10, left: 10, right: 10, child: Card(color: Colors.white.withOpacity(.94), child: Padding(padding: const EdgeInsets.all(10), child: Text(position == null ? 'Toque no alvo para localizar você' : currentPaddock != null ? 'Você está no ${currentPaddock.name}' : insideProperty ? 'Você está dentro da propriedade' : 'Você está fora do limite cadastrado', style: const TextStyle(fontWeight: FontWeight.bold))))),
      Positioned(right: 12, bottom: 172, child: FloatingActionButton.small(heroTag: 'gps', onPressed: _locate, child: const Icon(Icons.my_location))),
      Positioned(left: 10, right: 10, bottom: 10, child: Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [Expanded(child: TextField(controller: draftName, decoration: const InputDecoration(labelText: 'Nome: P1, P2...', isDense: true))), const SizedBox(width: 8), DropdownButton<AreaUnit>(value: unit, items: AreaUnit.values.map((u) => DropdownMenuItem(value: u, child: Text(u == AreaUnit.hectare ? 'ha' : u == AreaUnit.squareMeter ? 'm²' : 'alq.'))).toList(), onChanged: (u) { setState(() => unit = u!); _save(); })]),
        const SizedBox(height: 8),
        Wrap(spacing: 7, runSpacing: 7, children: [
          OutlinedButton.icon(onPressed: () => setState(() { draft.clear(); drawingProperty = true; }), icon: const Icon(Icons.border_outer), label: const Text('Limite da propriedade')),
          OutlinedButton.icon(onPressed: _toggleWalk, icon: Icon(walking ? Icons.stop : Icons.directions_walk), label: Text(walking ? 'Parar GPS' : 'Caminhar com GPS')),
          FilledButton.icon(onPressed: _finishDrawing, icon: const Icon(Icons.check), label: const Text('Concluir desenho')),
          TextButton(onPressed: () => setState(draft.clear), child: const Text('Limpar')),
        ]),
      ])))),
    ]);
  }

  Widget _paddockList() => ListView(padding: const EdgeInsets.all(16), children: [
        Text('Piquetes cadastrados', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        Text('Pastagem utilizada: ${unit.format(pastureAreaM2)}'),
        const SizedBox(height: 12),
        if (paddocks.isEmpty)
  const Card(
    child: Padding(
      padding: EdgeInsets.all(20),
      child: Text('Nenhum piquete cadastrado. Abra o mapa e desenhe o primeiro piquete.'),
    ),
  )
else
  ...paddocks.asMap().entries.map(
    (e) => Card(
      child: ListTile(
        leading: CircleAvatar(child: Text(e.value.name)),
        title: Text('${e.value.name} · ${unit.format(e.value.areaM2)}'),
        subtitle: Text('${e.value.points.length} pontos georreferenciados'),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline),
          onPressed: () {
            setState(() => paddocks.removeAt(e.key));
            _save();
          },
        ),
      ),
    ),
  ),
]);

  Widget _biomass() => ListView(padding: const EdgeInsets.all(16), children: [
        Text('Massa vegetal', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
        const Text('Estimativa por imagem Sentinel-2 combinada com calibração de campo.'),
        const SizedBox(height: 12),
        if (paddocks.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(20), child: Text('Cadastre os piquetes para iniciar o monitoramento.'))),
        ...paddocks.map((p) => Card(child: ListTile(leading: const Icon(Icons.grass, color: Color(0xFF237A3B)), title: Text(p.name), subtitle: Text(p.biomass <= 0 ? 'Aguardando imagem e calibração' : '${p.biomass.toStringAsFixed(0)} kg MS/ha'), trailing: const Icon(Icons.chevron_right)))),
        const SizedBox(height: 10),
        const Card(child: Padding(padding: EdgeInsets.all(14), child: Text('A estimativa de massa não deve usar apenas a cor do satélite. O Geopasto cruzará NDVI/EVI com amostras pesadas no campo para criar uma equação calibrada para a propriedade.'))),
      ]);
}
