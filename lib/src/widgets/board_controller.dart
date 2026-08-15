import 'package:dartchess/dartchess.dart';
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import 'animation.dart';
import 'board_painter.dart';
import '../fen.dart';
import '../models.dart';

/// Controls the board position, game state, and piece animations for a [Chessboard].
///
/// ## Interactivity
///
/// A controller drives a [Chessboard]. To make the board non-interactive (e.g.
/// at the end of a game), update it with game data whose `playerSide` is [PlayerSide.none].
/// For a fully static board, use [StaticChessboard] instead.
///
/// ## Updating the position
///
/// Call [updatePosition] after each move to advance the board. Pass
/// `animate: false` to switch positions without animation, and `resetPremove: true` to clear any
/// registered premove when jumping to an arbitrary position.
///
/// ## Premoves
///
/// Read [premove] or subscribe to [premoveNotifier] to detect the next pending premove.
/// By default [maxPremoveCount] is `1`, preserving the historical single-premove behavior.
/// Set it above `1` to queue several premoves. In that mode the board pieces are shown in a
/// speculative preview position obtained by applying the queued moves in order, while [fen] and
/// [game] continue to describe the latest authoritative position supplied by the parent.
///
/// The parent remains responsible for validating and executing the next premove after the opponent
/// moves. Once the head has been accepted, call [consumePremove] before submitting that move. If it
/// is no longer legal, clear the queue with `premove = null` or [clearPremoves].
///
/// ## Drawn shapes
///
/// User-drawn shapes are managed internally by the board via gestures.
/// External shapes are supplied via [Chessboard.shapes].
///
/// ## Atomic explosions
///
/// Call [triggerExplosion] with the set of squares to animate a one-shot
/// explosion (used in atomic chess).
///
/// The controller must be disposed when no longer needed.
class ChessboardController extends ChangeNotifier {
  /// Creates a controller for an interactive [Chessboard] driven by [game].
  ChessboardController({required GameData game}) {
    _gameNotifier = ValueNotifier(game);
    _piecesNotifier = ValueNotifier(readFen(game.fen));
    _translatingPiecesNotifier = ValueNotifier({});
    _fadingPiecesNotifier = ValueNotifier({});
    _highlightNotifier = BoardHighlightNotifier();
    _drawnShapesNotifier = ValueNotifier({});
    _pendingPromotionNotifier = ValueNotifier(null);
    _premoveNotifier = ValueNotifier(null);
  }

  Move? _lastDropMove;
  Set<Square>? _pendingExplosionSquares;
  final List<Move> _premoveQueue = [];
  Pieces? _premoveBasePieces;
  int _maxPremoveCount = 1;

  late final ValueNotifier<GameData> _gameNotifier;
  late final ValueNotifier<Pieces> _piecesNotifier;
  late final ValueNotifier<TranslatingPieces> _translatingPiecesNotifier;
  late final ValueNotifier<FadingPieces> _fadingPiecesNotifier;
  late final BoardHighlightNotifier _highlightNotifier;
  late final ValueNotifier<Set<Shape>> _drawnShapesNotifier;
  late final ValueNotifier<NormalMove?> _pendingPromotionNotifier;
  late final ValueNotifier<Move?> _premoveNotifier;

  AnimationController? _animationController;
  CurvedAnimation? _translationAnimation;
  CurvedAnimation? _fadeAnimation;

  // --- Public API ---

  String get fen => _gameNotifier.value.fen;
  GameData get game => _gameNotifier.value;
  Move? get lastMove => _gameNotifier.value.lastMove;
  bool get interactive => _gameNotifier.value.playerSide != PlayerSide.none;
  Pieces get pieces => _piecesNotifier.value;

  /// The next registered premove, or `null` if the queue is empty.
  ///
  /// This remains source-compatible with the historical single-premove API. In multiple-premove
  /// mode it is simply the head of [premoveQueue].
  Move? get premove => _premoveNotifier.value;

  /// Pending premoves in execution order.
  List<Move> get premoveQueue => List.unmodifiable(_premoveQueue);

  /// Maximum number of premoves that may be queued.
  ///
  /// The default value `1` preserves the legacy behavior. Values greater than `1` enable a
  /// speculative board preview so the destination of one premove can immediately become the
  /// origin of the next one.
  int get maxPremoveCount => _maxPremoveCount;
  set maxPremoveCount(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'maxPremoveCount', 'must be at least 1');
    }
    if (value == _maxPremoveCount) return;

    final wasMultiple = _maxPremoveCount > 1;
    _maxPremoveCount = value;

    if (_premoveQueue.isEmpty) return;

    if (value == 1) {
      // Switching back to single mode keeps only the current head and restores the authoritative
      // pieces, matching the historical no-preview behavior.
      final head = _premoveQueue.first;
      if (wasMultiple && _premoveBasePieces != null) {
        _piecesNotifier.value = Map<Square, Piece>.from(_premoveBasePieces!);
      }
      _premoveQueue
        ..clear()
        ..add(head);
      _premoveBasePieces = null;
      _premoveNotifier.value = head;
      notifyListeners();
    } else if (!wasMultiple) {
      // Enabling multiple mode while a single premove is already pending: use the current board as
      // the authoritative base and turn that existing head into the first speculative move.
      _premoveBasePieces = Map<Square, Piece>.from(_piecesNotifier.value);
      _rebuildPremovePreview();
      notifyListeners();
    } else if (_premoveQueue.length > value) {
      _premoveQueue.removeRange(value, _premoveQueue.length);
      _rebuildPremovePreview();
      _premoveNotifier.value = _premoveQueue.firstOrNull;
      notifyListeners();
    }
  }

  /// A notifier that fires whenever the queue head is set or cleared.
  ///
  /// Useful for parents that need to react to premove changes outside the board
  /// (e.g. updating pocket highlights, analytics, or haptic feedback).
  ValueNotifier<Move?> get premoveNotifier => _premoveNotifier;

  @internal
  Set<Square>? get pendingExplosionSquares => _pendingExplosionSquares;

  @internal
  Iterable<Shape> get drawnShapes => _drawnShapesNotifier.value;

  // --- Notifiers consumed by board painters (internal use only) ---

  @internal
  ValueNotifier<GameData?> get gameNotifier => _gameNotifier;
  @internal
  ValueNotifier<Pieces> get piecesNotifier => _piecesNotifier;
  @internal
  ValueNotifier<TranslatingPieces> get translatingPiecesNotifier => _translatingPiecesNotifier;
  @internal
  ValueNotifier<FadingPieces> get fadingPiecesNotifier => _fadingPiecesNotifier;
  @internal
  BoardHighlightNotifier get highlightNotifier => _highlightNotifier;
  @internal
  ValueNotifier<Set<Shape>> get drawnShapesNotifier => _drawnShapesNotifier;
  @internal
  ValueNotifier<NormalMove?> get pendingPromotionNotifier => _pendingPromotionNotifier;

  @internal
  CurvedAnimation get translationAnimation {
    assert(_translationAnimation != null, 'ChessboardController is not attached to a board.');
    return _translationAnimation!;
  }

  @internal
  CurvedAnimation get fadeAnimation {
    assert(_fadeAnimation != null, 'ChessboardController is not attached to a board.');
    return _fadeAnimation!;
  }

  // --- Lifecycle (called by _BoardState) ---

  @internal
  void attachTo(TickerProvider vsync, Duration animationDuration) {
    assert(_animationController == null, 'ChessboardController is already attached to a board.');
    _animationController = AnimationController(
      animationBehavior: AnimationBehavior.preserve,
      duration: animationDuration,
      vsync: vsync,
    );
    _translationAnimation = CurvedAnimation(
      parent: _animationController!,
      curve: Curves.easeInOutCubic,
    );
    _fadeAnimation = CurvedAnimation(parent: _animationController!, curve: Curves.easeInQuad);
    _animationController!.addStatusListener(_onAnimationStatusChanged);
    // Re-attaching with animation pieces still pending means an animation was
    // interrupted by a detach/attach cycle (e.g. the board being reparented
    // during an Android predictive-back gesture). The fresh controller sits at
    // value 0.0, so the translating painter would otherwise draw those pieces
    // frozen at their origin. Commit them straight to the static position; the
    // destination is already reflected in [_piecesNotifier].
    _commitAnimationPieces();
  }

  void _onAnimationStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed) _commitAnimationPieces();
  }

  /// Drops the translating/fading pieces into the static position.
  ///
  /// The translating pieces have reached their destination (already present in
  /// [_piecesNotifier]) and the fading pieces are gone, so clearing the notifiers
  /// while attached lets the static painter — which skips translating squares —
  /// repaint them, leaving the board in a clean resting state with no lingering
  /// animation pieces that a later detach/attach could resurrect as ghosts.
  void _commitAnimationPieces() {
    if (_translatingPiecesNotifier.value.isNotEmpty) {
      _translatingPiecesNotifier.value = {};
    }
    if (_fadingPiecesNotifier.value.isNotEmpty) {
      _fadingPiecesNotifier.value = {};
    }
  }

  @internal
  void detach() {
    _animationController?.removeStatusListener(_onAnimationStatusChanged);
    _fadeAnimation?.dispose();
    _translationAnimation?.dispose();
    _animationController?.dispose();
    _fadeAnimation = null;
    _translationAnimation = null;
    _animationController = null;
    // Note: the translating/fading notifiers are intentionally left untouched
    // here. A completed animation is already committed to the static position by
    // [_onAnimationStatusChanged], and an interrupted one is committed on the next
    // [attachTo], so a detach/attach cycle (e.g. the board being reparented during
    // an Android predictive-back gesture) finds no stale animation state to
    // resurrect. Clearing them here instead would race with the static layer's
    // retained picture on reattach and make the destination pieces briefly
    // disappear.
  }

  @internal
  Duration get animationDuration => _animationController?.duration ?? Duration.zero;
  @internal
  set animationDuration(Duration value) {
    _animationController?.duration = value;
  }

  // --- Premove helpers ---

  Side? get _playerColor => switch (_gameNotifier.value.playerSide) {
    PlayerSide.white => Side.white,
    PlayerSide.black => Side.black,
    _ => null,
  };

  bool _tryPreviewCastle(Pieces pieces, Piece king, Square from, Square to) {
    if (king.role != Role.king || from.rank != to.rank) return false;

    Square? rookSquare;
    final destinationPiece = pieces[to];
    if (destinationPiece?.role == Role.rook && destinationPiece?.color == king.color) {
      rookSquare = to;
    } else if (to.file == 6) {
      final candidate = Square.fromCoords(File(7), from.rank);
      final rook = pieces[candidate];
      if (rook?.role == Role.rook && rook?.color == king.color) rookSquare = candidate;
    } else if (to.file == 2) {
      final candidate = Square.fromCoords(File(0), from.rank);
      final rook = pieces[candidate];
      if (rook?.role == Role.rook && rook?.color == king.color) rookSquare = candidate;
    }

    if (rookSquare == null) return false;

    final kingDestFile = rookSquare.file > from.file ? 6 : 2;
    final rookDestFile = rookSquare.file > from.file ? 5 : 3;
    final kingDest = Square.fromCoords(File(kingDestFile), from.rank);
    final rookDest = Square.fromCoords(File(rookDestFile), from.rank);
    final rook = pieces[rookSquare]!;

    pieces
      ..remove(from)
      ..remove(rookSquare)
      ..[kingDest] = king
      ..[rookDest] = rook;
    return true;
  }

  bool _applyPreviewMove(Pieces pieces, Move move) {
    switch (move) {
      case NormalMove(:final from, :final to, :final promotion):
        final piece = pieces[from];
        if (piece == null || from == to) return false;
        if (_tryPreviewCastle(pieces, piece, from, to)) return true;
        pieces.remove(from);
        pieces[to] = promotion != null ? piece.copyWith(role: promotion, promoted: true) : piece;
        return true;
      case DropMove(:final to, :final role):
        final color = _playerColor;
        if (color == null) return false;
        pieces[to] = Piece(role: role, color: color);
        return true;
    }
  }

  bool _rebuildPremovePreview() {
    if (_maxPremoveCount <= 1 || _premoveQueue.isEmpty) return true;
    final base = _premoveBasePieces;
    if (base == null) return false;
    final preview = Map<Square, Piece>.from(base);
    for (final move in _premoveQueue) {
      if (!_applyPreviewMove(preview, move)) {
        _piecesNotifier.value = Map<Square, Piece>.from(base);
        return false;
      }
    }
    _piecesNotifier.value = preview;
    return true;
  }

  void _clearPremoves({required bool restoreAuthoritativePieces}) {
    if (restoreAuthoritativePieces && _premoveBasePieces != null) {
      _piecesNotifier.value = Map<Square, Piece>.from(_premoveBasePieces!);
    }
    _premoveQueue.clear();
    _premoveBasePieces = null;
    _premoveNotifier.value = null;
    notifyListeners();
  }

  /// Removes and returns the head premove after the parent has validated it.
  ///
  /// In multiple-premove mode this advances the speculative base by that move and preserves the
  /// remaining tail. The next authoritative [updatePosition] will replace that predicted base with
  /// the server-confirmed position and reapply the tail.
  Move? consumePremove() {
    if (_premoveQueue.isEmpty) return null;
    final move = _premoveQueue.first;

    if (_maxPremoveCount <= 1) {
      _premoveQueue.clear();
      _premoveNotifier.value = null;
      notifyListeners();
      return move;
    }

    final base = _premoveBasePieces;
    if (base == null) {
      _clearPremoves(restoreAuthoritativePieces: false);
      return move;
    }

    final advancedBase = Map<Square, Piece>.from(base);
    if (!_applyPreviewMove(advancedBase, move)) {
      _clearPremoves(restoreAuthoritativePieces: true);
      return move;
    }

    _premoveQueue.removeAt(0);
    if (_premoveQueue.isEmpty) {
      _premoveBasePieces = null;
      _piecesNotifier.value = advancedBase;
      _premoveNotifier.value = null;
    } else {
      _premoveBasePieces = advancedBase;
      _premoveNotifier.value = _premoveQueue.first;
      if (!_rebuildPremovePreview()) {
        _clearPremoves(restoreAuthoritativePieces: true);
        return move;
      }
    }
    notifyListeners();
    return move;
  }

  /// Clears every queued premove and restores the latest authoritative board position.
  void clearPremoves() => _clearPremoves(restoreAuthoritativePieces: true);

  // --- Public mutation API ---

  /// Sets, queues, or clears a premove.
  ///
  /// With the default [maxPremoveCount] of `1`, assigning a non-null [Move] replaces the existing
  /// premove exactly as before and does not move any displayed pieces. When [maxPremoveCount] is
  /// greater than `1`, non-null assignments append to the queue and immediately advance the
  /// speculative preview. Assign `null` to clear the complete queue.
  set premove(Move? move) {
    if (move == null) {
      _clearPremoves(restoreAuthoritativePieces: true);
      return;
    }

    if (_maxPremoveCount <= 1) {
      _premoveQueue
        ..clear()
        ..add(move);
      _premoveBasePieces = null;
      _premoveNotifier.value = move;
      return;
    }

    if (_premoveQueue.length >= _maxPremoveCount) return;
    _premoveBasePieces ??= Map<Square, Piece>.from(_piecesNotifier.value);

    final preview = Map<Square, Piece>.from(_piecesNotifier.value);
    if (!_applyPreviewMove(preview, move)) return;

    _premoveQueue.add(move);
    _piecesNotifier.value = preview;
    _premoveNotifier.value = _premoveQueue.first;
    notifyListeners();
  }

  /// The pending promotion move, or `null` when no promotion is in progress.
  NormalMove? get pendingPromotion => _pendingPromotionNotifier.value;

  /// Sets or clears the pending promotion move.
  ///
  /// Setting a non-null value causes the board to show the promotion selector.
  /// Typically set when executing a premove that turns out to be a promotion and
  /// [ChessboardSettings.autoQueenPromotionOnPremove] is disabled.
  set pendingPromotion(NormalMove? move) {
    _pendingPromotionNotifier.value = move;
  }

  @internal
  void toggleDrawnShape(Shape shape) {
    final current = _drawnShapesNotifier.value;
    _drawnShapesNotifier.value =
        current.contains(shape) ? current.difference({shape}) : {...current, shape};
  }

  /// Removes all user-drawn shapes from the board.
  ///
  /// This does not affect externally supplied shapes passed via [Chessboard.shapes].
  void clearDrawnShapes() {
    _drawnShapesNotifier.value = {};
  }

  /// Records that [move] was just performed via drag and drop.
  ///
  /// Called internally by the board when the user completes a move by dropping a
  /// piece (a board drag or an external pocket drop). The next [updatePosition]
  /// uses this to suppress the redundant translation of the already-dragged
  /// piece, then clears it.
  @internal
  // ignore: use_setters_to_change_properties
  void recordDropMove(Move move) {
    _lastDropMove = move;
  }

  /// Triggers a one-shot explosion animation on the given squares.
  ///
  /// Typically used for atomic chess: pass the set of exploded squares (capture
  /// square + adjacent non-pawn pieces) after a capture. The board fires the
  /// animation the first time it sees a new, non-null set; calling this method
  /// with the exact same [Set] reference a second time has no effect. To
  /// re-trigger with identical squares pass a new [Set] instance.
  void triggerExplosion(Set<Square> squares) {
    _pendingExplosionSquares = squares;
    notifyListeners();
  }

  Pieces _displayPiecesForAuthoritative(Pieces authoritative) {
    if (_maxPremoveCount <= 1 || _premoveQueue.isEmpty) {
      _premoveBasePieces = null;
      return authoritative;
    }

    _premoveBasePieces = Map<Square, Piece>.from(authoritative);
    final preview = Map<Square, Piece>.from(authoritative);
    for (final move in _premoveQueue) {
      if (!_applyPreviewMove(preview, move)) return authoritative;
    }
    return preview;
  }

  /// Updates the board to [game].
  ///
  /// By default, pieces are animated to their new positions. Pass
  /// `animate: false` to switch positions instantly (e.g. analysis seeking or
  /// history navigation).
  ///
  /// By default, any registered premove is preserved. In multiple-premove mode the new FEN becomes
  /// the authoritative preview base and the still-pending queue is reapplied on top of it. Pass
  /// `resetPremove: true` to clear the complete queue — appropriate whenever the new position is not
  /// a direct continuation of the current one (e.g. jumping to an arbitrary position).
  ///
  /// If the triggering move was performed via drag and drop (recorded by the
  /// board through [recordDropMove]), the animation engine automatically
  /// suppresses the redundant translation of the dragged piece.
  void updatePosition(GameData game, {bool animate = true, bool resetPremove = false}) {
    if (!animate) {
      _animationController?.stop();
      _translatingPiecesNotifier.value = {};
      _fadingPiecesNotifier.value = {};
      _lastDropMove = null;
      final authoritative = readFen(game.fen);
      if (resetPremove) {
        _premoveQueue.clear();
        _premoveBasePieces = null;
        _premoveNotifier.value = null;
        _piecesNotifier.value = authoritative;
      } else {
        _piecesNotifier.value = _displayPiecesForAuthoritative(authoritative);
      }
      _gameNotifier.value = game;
      notifyListeners();
      return;
    }

    if (game.fen != fen) {
      final lastDrop = _lastDropMove;
      _lastDropMove = null;
      final oldPieces = _piecesNotifier.value;
      _translatingPiecesNotifier.value = {};
      _fadingPiecesNotifier.value = {};

      final authoritative = readFen(game.fen);
      if (resetPremove) {
        _premoveQueue.clear();
        _premoveBasePieces = null;
        _premoveNotifier.value = null;
      }
      final newPieces = resetPremove ? authoritative : _displayPiecesForAuthoritative(authoritative);

      if ((_animationController?.duration ?? Duration.zero) > Duration.zero) {
        final (tp, fp) = preparePieceAnimations(oldPieces, newPieces, lastDrop: lastDrop);
        _translatingPiecesNotifier.value = tp;
        _fadingPiecesNotifier.value = fp;
      }

      if (_translatingPiecesNotifier.value.isNotEmpty || _fadingPiecesNotifier.value.isNotEmpty) {
        _animationController?.forward(from: 0.0);
      } else {
        _animationController?.stop();
      }

      _piecesNotifier.value = newPieces;
    }

    _gameNotifier.value = game;
    if (resetPremove && game.fen == fen) {
      _clearPremoves(restoreAuthoritativePieces: true);
    }

    notifyListeners();
  }

  @override
  void dispose() {
    detach();
    _gameNotifier.dispose();
    _piecesNotifier.dispose();
    _translatingPiecesNotifier.dispose();
    _fadingPiecesNotifier.dispose();
    _highlightNotifier.dispose();
    _drawnShapesNotifier.dispose();
    _pendingPromotionNotifier.dispose();
    _premoveNotifier.dispose();
    super.dispose();
  }
}
