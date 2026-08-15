import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

GameData _game({
  required String fen,
  required Side sideToMove,
  PlayerSide playerSide = PlayerSide.white,
}) =>
    GameData(
      fen: fen,
      playerSide: playerSide,
      sideToMove: sideToMove,
      validMoves: const <Square, Set<Square>>{},
    );

NormalMove _move(Square from, Square to) => NormalMove(from: from, to: to);

void main() {
  group('ChessboardController multiple premoves', () {
    late ChessboardController controller;

    setUp(() {
      controller = ChessboardController(
        game: _game(
          fen: '7k/8/8/8/8/8/6K1/8 b - - 0 1',
          sideToMove: Side.black,
        ),
      );
    });

    tearDown(() => controller.dispose());

    test('single premove mode preserves legacy non-preview behaviour', () {
      final premove = _move(Square.g2, Square.f2);

      controller.premove = premove;

      expect(controller.premove, premove);
      expect(controller.premoveQueue, [premove]);
      expect(controller.pieces[Square.g2]?.role, Role.king);
      expect(controller.pieces[Square.f2], isNull);
    });

    test('multiple mode appends moves and advances a speculative preview', () {
      controller.maxPremoveCount = 4;
      final first = _move(Square.g2, Square.f2);
      final second = _move(Square.f2, Square.e2);

      controller.premove = first;
      expect(controller.pieces[Square.g2], isNull);
      expect(controller.pieces[Square.f2]?.role, Role.king);

      controller.premove = second;

      expect(controller.premove, first);
      expect(controller.premoveQueue, [first, second]);
      expect(controller.pieces[Square.f2], isNull);
      expect(controller.pieces[Square.e2]?.role, Role.king);
    });

    test('authoritative update is used as a new base while keeping the queue preview', () {
      controller.maxPremoveCount = 4;
      final first = _move(Square.g2, Square.f2);
      final second = _move(Square.f2, Square.e2);
      controller
        ..premove = first
        ..premove = second;

      controller.updatePosition(
        _game(
          fen: '8/7k/8/8/8/8/6K1/8 w - - 1 2',
          sideToMove: Side.white,
        ),
        animate: false,
      );

      expect(controller.fen, '8/7k/8/8/8/8/6K1/8 w - - 1 2');
      expect(controller.premoveQueue, [first, second]);
      expect(controller.pieces[Square.e2]?.role, Role.king);
    });

    test('consuming a legal head preserves the dependent tail', () {
      controller.maxPremoveCount = 4;
      final first = _move(Square.g2, Square.f2);
      final second = _move(Square.f2, Square.e2);
      controller
        ..premove = first
        ..premove = second;

      controller.updatePosition(
        _game(
          fen: '8/7k/8/8/8/8/6K1/8 w - - 1 2',
          sideToMove: Side.white,
        ),
        animate: false,
      );

      expect(controller.consumePremove(), first);
      expect(controller.premove, second);
      expect(controller.premoveQueue, [second]);
      expect(controller.pieces[Square.e2]?.role, Role.king);
    });

    test('clearing an invalid queue restores the latest authoritative position', () {
      controller.maxPremoveCount = 4;
      controller
        ..premove = _move(Square.g2, Square.f2)
        ..premove = _move(Square.f2, Square.e2);

      controller.updatePosition(
        _game(
          fen: '8/7k/8/8/8/8/6K1/8 w - - 1 2',
          sideToMove: Side.white,
        ),
        animate: false,
      );

      controller.clearPremoves();

      expect(controller.premove, isNull);
      expect(controller.premoveQueue, isEmpty);
      expect(controller.pieces[Square.g2]?.role, Role.king);
      expect(controller.pieces[Square.f2], isNull);
      expect(controller.pieces[Square.e2], isNull);
    });

    test('switching back to one premove keeps the head and removes preview tail', () {
      controller.maxPremoveCount = 4;
      final first = _move(Square.g2, Square.f2);
      controller
        ..premove = first
        ..premove = _move(Square.f2, Square.e2);

      controller.maxPremoveCount = 1;

      expect(controller.premove, first);
      expect(controller.premoveQueue, [first]);
      expect(controller.pieces[Square.g2]?.role, Role.king);
      expect(controller.pieces[Square.f2], isNull);
      expect(controller.pieces[Square.e2], isNull);
    });

    test('queue is capped at maxPremoveCount', () {
      controller.maxPremoveCount = 2;
      final first = _move(Square.g2, Square.f2);
      final second = _move(Square.f2, Square.e2);
      controller
        ..premove = first
        ..premove = second
        ..premove = _move(Square.e2, Square.d2);

      expect(controller.premoveQueue, [first, second]);
      expect(controller.pieces[Square.e2]?.role, Role.king);
      expect(controller.pieces[Square.d2], isNull);
    });
  });
}
