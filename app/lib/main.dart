import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/measure_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Paisagem fixa: assim a linha laser horizontal na tela também é
  // horizontal no buffer do sensor (sem rotacionar quadros no isolate).
  await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MedidorSulcoApp());
}

class MedidorSulcoApp extends StatelessWidget {
  const MedidorSulcoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Medidor de Sulco',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1F6FEB),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const MeasureScreen(),
    );
  }
}
