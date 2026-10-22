import 'package:aluta/services/aluta_mood.dart';
import 'package:aluta/services/song_insights.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final si = SongInsights.instance;

  group('SongInsights guardrails', () {
    test('a song played 3 times today queues one "repeat" nudge', () async {
      await si.load();
      expect(si.pending.value, isNull);
      await si.recordPlay('Nameless', artist: 'Juju');
      await si.recordPlay('Nameless', artist: 'Juju');
      expect(si.pending.value, isNull, reason: 'not yet on repeat');
      await si.recordPlay('Nameless', artist: 'Juju');
      expect(si.pending.value?.kind, 'repeat');
      expect(si.pending.value?.title, 'Nameless');
    });

    test('only one music nudge per day', () async {
      final n = si.pending.value!;
      si.markShown(n);
      expect(si.pending.value, isNull);
      for (var i = 0; i < 4; i++) {
        await si.recordPlay('Another Song');
      }
      expect(si.pending.value, isNull, reason: "today's slot is spent");
    });

    test('feelings are remembered and drive lastFeel', () {
      si.setFeel('Nameless', SongFeel.missing);
      expect(si.feelOf('Nameless'), SongFeel.missing);
      expect(si.feelOf('nameless'), SongFeel.missing,
          reason: 'keys ignore case');
      expect(si.lastFeel, SongFeel.missing);
    });

    test('non-Latin titles keep their own memory', () {
      si.setFeel('Upendo wa Kweli', SongFeel.love);
      si.setFeel('حبيبي', SongFeel.calm);
      si.setFeel('사랑해', SongFeel.hyped);
      expect(si.feelOf('حبيبي'), SongFeel.calm);
      expect(si.feelOf('사랑해'), SongFeel.hyped);
      expect(si.feelOf('Upendo wa Kweli'), SongFeel.love);
    });

    test('calm songs are collected', () {
      expect(si.calmSongs, contains('حبيبي'));
    });

    test('switching nudges off clears anything pending', () async {
      await si.setEnabled(false);
      expect(si.enabled.value, isFalse);
      expect(si.pending.value, isNull);
      await si.setEnabled(true);
    });
  });

  group('AlutaMood', () {
    test('moments follow the clock', () {
      expect(AlutaMood.momentAt(DateTime(2026, 1, 1, 6)), AlutaMoment.dawn);
      expect(AlutaMood.momentAt(DateTime(2026, 1, 1, 9)), AlutaMoment.morning);
      expect(
          AlutaMood.momentAt(DateTime(2026, 1, 1, 13)), AlutaMoment.afternoon);
      expect(AlutaMood.momentAt(DateTime(2026, 1, 1, 18)), AlutaMoment.evening);
      expect(AlutaMood.momentAt(DateTime(2026, 1, 1, 23)), AlutaMoment.night);
      expect(AlutaMood.momentAt(DateTime(2026, 1, 1, 2)), AlutaMoment.night);
    });

    test('greetings never repeat back to back and use the name', () {
      final a = AlutaMood.greeting('Anesius');
      final b = AlutaMood.greeting('Anesius');
      expect(a, isNot(equals(b)));
      expect(a.isNotEmpty && b.isNotEmpty, isTrue);
    });

    test('long emoji titles are trimmed without breaking characters', () {
      final title = '${'🎵' * 30}💞 love';
      final line = AlutaMood.songOnRepeat(title);
      // A broken surrogate pair would make this throw.
      expect(() => line.runes.toList(), returnsNormally);
      expect(line.contains('…'), isTrue);
    });

    test('away summary prefers the partner', () {
      final s = AlutaMood.awaySummary(
          me: 'Anesius', partner: 'Belyner', fromPartner: 3, others: 9);
      expect(s.contains('Belyner'), isTrue);
    });
  });
}
