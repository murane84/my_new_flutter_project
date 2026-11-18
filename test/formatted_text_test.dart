// Chat formatting markers only around whole words (file names stay intact).
import 'package:aluta/screens/chat/formatted_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a file name with underscores reads exactly as attached', () {
    const name = 'Report_Existing_Problems_AC_Distribution_System_Dar.pdf';
    expect(stripMessageFormatting(name), name);
    expect(stripMessageFormatting('my_file_v2_final.docx'),
        'my_file_v2_final.docx');
  });

  test('formatting around whole words still works', () {
    expect(stripMessageFormatting('*Hello* _world_'), 'Hello world');
    expect(stripMessageFormatting('snake_case and _italic_ and ~old~'),
        'snake_case and italic and old');
    expect(stripMessageFormatting('(_note_)'), '(note)');
    expect(stripMessageFormatting('2*3*4'), '2*3*4');
  });
}
