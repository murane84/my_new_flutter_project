import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';

/// A single-line label that gently auto-scrolls (marquee) ONLY when the text is
/// too wide to fit its available width; short text renders as a plain static
/// label. Keeps long song titles on one line instead of wrapping and eating
/// vertical space.
class MarqueeText extends StatelessWidget {
  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.height = 20,
    this.velocity = 26,
  });

  final String text;
  final TextStyle style;
  final double height;
  final double velocity;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();
        final overflows = tp.width > constraints.maxWidth;
        if (!overflows) {
          return Text(text,
              style: style, maxLines: 1, overflow: TextOverflow.clip);
        }
        return SizedBox(
          height: height,
          child: Marquee(
            text: text,
            style: style,
            blankSpace: 46,
            velocity: velocity,
            pauseAfterRound: const Duration(seconds: 2),
            fadingEdgeStartFraction: 0.06,
            fadingEdgeEndFraction: 0.12,
            showFadingOnlyWhenScrolling: true,
          ),
        );
      },
    );
  }
}
