import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/theme_provider.dart';

class AnimatedBackground extends StatefulWidget {
  const AnimatedBackground({super.key});

  @override
  State<AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<AnimatedBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController controller;

  final List<Particle> particles = [];
  final List<MusicNote> notes = [];
  final List<ChatBubble> bubbles = [];
  final Random random = Random();

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    // Generate particles ONCE
    for (int i = 0; i < 90; i++) {
      particles.add(
        Particle(
          x: random.nextDouble(),
          y: random.nextDouble(),
          speed: random.nextDouble() * 0.3 + 0.1,
          radius: random.nextDouble() * 2 + 1,
        ),
      );
    }

    // Generate music notes ONCE
    for (int i = 0; i < 20; i++) {
      notes.add(
        MusicNote(
          x: random.nextDouble(),
          y: random.nextDouble(),
          speed: random.nextDouble() * 0.5 + 0.2,
          size: random.nextDouble() * 20 + 10,
        ),
      );
    }

    // Generate chat bubbles ONCE
    for (int i = 0; i < 10; i++) {
      bubbles.add(
        ChatBubble(
          x: random.nextDouble(),
          y: random.nextDouble(),
          speed: random.nextDouble() * 0.3 + 0.1,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeProvider>().isDarkMode;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, _) {
          return CustomPaint(
            painter: BackgroundPainter(
              progress: controller.value,
              particles: particles,
              notes: notes,
              bubbles: bubbles,
              isDark: isDark,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

// Models and Painters
class Particle {
  double x;
  double y;
  double speed;
  double radius;

  Particle({
    required this.x,
    required this.y,
    required this.speed,
    required this.radius,
  });
}

class MusicNote {
  double x;
  double y;
  double speed;
  double size;

  MusicNote({
    required this.x,
    required this.y,
    required this.speed,
    required this.size,
  });
}

class ChatBubble {
  double x;
  double y;
  double speed;

  ChatBubble({required this.x, required this.y, required this.speed});
}

// Custom OPTIMIZED painter for the animated background
class BackgroundPainter extends CustomPainter {
  final double progress;
  final List<Particle> particles;
  final List<MusicNote> notes;
  final List<ChatBubble> bubbles;
  final bool isDark;

  BackgroundPainter({
    required this.progress,
    required this.particles,
    required this.notes,
    required this.bubbles,
    required this.isDark,
  });

  final Paint particlePaint = Paint()..color = Colors.redAccent.withAlpha(120);
  final Paint notePaint = Paint()
    ..color = const Color.fromARGB(255, 251, 3, 251).withAlpha(120);
  final Paint bubblePaint = Paint()
    ..color = Colors.red.withAlpha(70)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final baseColor = isDark ? Colors.black : Colors.white;

    final gradient = LinearGradient(
      colors: [baseColor, Colors.red.withAlpha(isDark ? 60 : 40), baseColor],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );

    final paint = Paint()
      ..shader = gradient.createShader(
        Rect.fromLTWH(0, 0, size.width, size.height),
      );

    canvas.drawRect(Offset.zero & size, paint);

    // Draw particles
    for (final p in particles) {
      double y =
          (p.y * size.height + progress * p.speed * size.height) % size.height;

      double x = p.x * size.width;

      canvas.drawCircle(Offset(x, y), p.radius, particlePaint);
    }

    // Draw music notes
    for (final n in notes) {
      double y =
          (n.y * size.height + progress * n.speed * size.height) % size.height;

      double x = n.x * size.width;

      final textPainter = TextPainter(
        text: TextSpan(
          text: "♪",
          style: TextStyle(fontSize: n.size, color: Colors.red.withAlpha(160)),
        ),
        textDirection: TextDirection.ltr,
      );

      textPainter.layout();

      textPainter.paint(canvas, Offset(x, y));
    }

    // Draw chat bubbles
    for (final b in bubbles) {
      double y =
          (b.y * size.height + progress * b.speed * size.height) % size.height;

      double x = b.x * size.width;

      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(x, y), width: 20, height: 14),
        const Radius.circular(4),
      );

      canvas.drawRRect(rect, bubblePaint);

      canvas.drawLine(
        Offset(x - 6, y + 6),
        Offset(x - 10, y + 10),
        bubblePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant BackgroundPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.isDark != isDark;
  }
}
