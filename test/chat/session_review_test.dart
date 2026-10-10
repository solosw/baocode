import 'dart:async';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoStore implements ReviewStore {
  _NoStore(this.root);

  @override
  final String root;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A review that records what the session asks of it.
class _Review extends ChangeReview {
  _Review({String root = '/p'}) : super(_NoStore(root));

  final calls = <String>[];
  final reported = <String>[];
  Completer<void>? holdBegin;
  Object? beginError;
  bool disposed = false;
  List<FileChange> listed = const [];

  @override
  List<FileChange> get changes => listed;

  void list(List<FileChange> changes) {
    listed = changes;
    notifyListeners();
  }

  @override
  Future<void> begin() async {
    calls.add('begin');
    await holdBegin?.future;
    if (beginError case final error?) throw error;
  }

  @override
  Future<void> observe({bool full = true}) async =>
      calls.add(full ? 'observe' : 'observe reported');

  @override
  void report(FileChange change) => reported.add(change.path);

  @override
  Future<void> keep(Iterable<String> paths) async =>
      calls.add('keep ${paths.join(',')}');

  @override
  Future<void> keepAll() async => calls.add('keepAll');

  @override
  Future<void> undo(Iterable<String> paths) async =>
      calls.add('undo ${paths.join(',')}');

  @override
  Future<void> undoAll() async => calls.add('undoAll');

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  late _Review review;

  Future<ChatSession> pump(
    WidgetTester tester, {
    KernelContext context = const KernelContext(cwd: '/p'),
    ChangeReviewOpener? openReview,
  }) async {
    review = _Review();
    final session = ChatSession(
      kernel: MockKernels.claudeCode,
      kernelContext: context,
      historyCount: 0,
      openReview: openReview ?? (root, {session}) async => review,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: ChatScreen(session: session),
      ),
    );
    await tester.pump();
    return session;
  }

  Future<void> finish(WidgetTester tester, ChatSession session) async {
    // The message goes once the snapshot before it is taken.
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 400 && session.isStreaming; i++) {
      switch (session.pendingInteraction) {
        case QuestionRequest():
          session.answer(const QuestionAnswer([], skipped: true));
        case ApprovalRequest():
          session.answer(const ApprovalAnswer(ApprovalDecision.allowOnce));
        default:
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('a message waits for the snapshot before it', (tester) async {
    final session = await pump(tester);
    // The project was snapshotted as the conversation showed.
    expect(review.calls, ['begin']);

    review.holdBegin = Completer();
    session.send(const ComposerMessage(text: '把输入框改成随内容增高'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(review.calls, ['begin', 'begin']);
    expect(session.itemCount, 0);

    review.holdBegin!.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(session.itemCount, greaterThan(0));
    await finish(tester, session);

    // The edits it reported were looked at, and all at the turn's end.
    expect(review.reported, isNotEmpty);
    expect(review.calls, contains('observe reported'));
    expect(review.calls.last, 'observe');
    // Its background tests settle.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a message still goes when opening the review never returns', (
    tester,
  ) async {
    // As a multi-folder workspace can: one folder's store hangs, the
    // open never completes. 1.0.7 only opened the empty workspace
    // folder; openAll must not keep the composer forever.
    final hang = Completer<ChangeReview?>();
    final session = ChatSession(
      kernel: MockKernels.claudeCode,
      kernelContext: const KernelContext(cwd: '/p'),
      historyCount: 0,
      openReview: (root, {session}) => hang.future,
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: ChatScreen(session: session),
      ),
    );
    await tester.pump();

    session.send(const ComposerMessage(text: 'hello'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(session.itemCount, 0);

    await tester.pump(const Duration(seconds: 30));
    expect(session.itemCount, greaterThan(0));
    await finish(tester, session);
    // Background mock work settles, as the other cases wait.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a workspace sends even when an added folder never opens', (
    tester,
  ) async {
    final hang = Completer<ChangeReview?>();
    final roots = <String>[];
    final added = _Review(root: '/added');
    final session = await pump(
      tester,
      context: KernelContext(
        cwd: '/p',
        workspace: () => const KernelWorkspace(folders: ['/added', '/added']),
      ),
      openReview: (root, {session}) {
        roots.add(root);
        return root == '/p' ? Future.value(review) : hang.future;
      },
    );
    expect(roots, ['/p', '/added']);

    session.send(const ComposerMessage(text: 'hello'));
    await tester.pump(const Duration(seconds: 30));
    expect(session.itemCount, greaterThan(0));

    // A late open must be disposed, not take a baseline after the send.
    hang.complete(added);
    await tester.pump();
    expect(review.disposed, isFalse);
    expect(review.failure, isNull);
    expect(added.disposed, isTrue);
    expect(review.calls, contains('begin'));
    expect(added.calls, isEmpty);
    await finish(tester, session);

    final before = session.itemCount;
    session.send(const ComposerMessage(text: 'next'));
    await tester.pump();
    expect(session.itemCount, greaterThan(before));
    await finish(tester, session);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
    'a healthy workspace sends with snapshots and undo still active',
    (tester) async {
      final added = _Review(root: '/added');
      final session = await pump(
        tester,
        context: KernelContext(
          cwd: '/p',
          workspace: () => const KernelWorkspace(folders: ['/added']),
        ),
        openReview: (root, {session}) async => root == '/p' ? review : added,
      );

      session.send(const ComposerMessage(text: 'hello'));
      await tester.pump();
      expect(session.itemCount, greaterThan(0));
      expect(review.calls, ['begin', 'begin']);
      expect(added.calls, ['begin', 'begin']);
      expect(review.failure, isNull);
      expect(added.failure, isNull);
      await finish(tester, session);

      const change = FileChange(path: '/added/a.dart', added: 1, removed: 1);
      added.list([change]);
      await tester.pump();
      expect(session.fileChanges, [change]);
      expect(session.undoChanges, isNotNull);
      session.undoChanges!([change]);
      await tester.pump();
      expect(added.calls, contains('undo /added/a.dart'));

      session.send(const ComposerMessage(text: 'next'));
      await tester.pump();
      expect(review.calls.where((call) => call == 'begin').length, 3);
      expect(added.calls.where((call) => call == 'begin').length, 3);
      expect(review.failure, isNull);
      expect(added.failure, isNull);
      await finish(tester, session);
      await tester.pump(const Duration(seconds: 5));
    },
  );

  testWidgets('a stuck workspace snapshot does not block later messages', (
    tester,
  ) async {
    final added = _Review(root: '/added');
    final session = await pump(
      tester,
      context: KernelContext(
        cwd: '/p',
        workspace: () => const KernelWorkspace(folders: ['/added']),
      ),
      openReview: (root, {session}) async => root == '/p' ? review : added,
    );
    expect(review.calls, ['begin']);
    expect(added.calls, ['begin']);
    added.holdBegin = Completer();

    session.send(const ComposerMessage(text: 'hello'));
    await tester.pump();
    expect(session.itemCount, 0);
    expect(added.calls, ['begin', 'begin']);
    await tester.pump(const Duration(seconds: 30));
    expect(session.itemCount, greaterThan(0));
    expect(review.failure, isNotNull);
    expect(added.failure, isNotNull);
    await finish(tester, session);

    final before = session.itemCount;
    session.send(const ComposerMessage(text: 'next'));
    await tester.pump();
    expect(session.itemCount, greaterThan(before));
    expect(added.calls.where((call) => call == 'begin').length, 2);
    added.holdBegin!.complete();
    await finish(tester, session);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('opening and snapshotting share the send wait budget', (
    tester,
  ) async {
    final delayed = Completer<ChangeReview?>();
    final session = await pump(
      tester,
      openReview: (root, {session}) => delayed.future,
    );
    review.holdBegin = Completer();
    session.send(const ComposerMessage(text: 'hello'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 29));
    delayed.complete(review);
    await tester.pump();
    expect(session.itemCount, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(session.itemCount, greaterThan(0));
    expect(review.failure, isNotNull);
    review.holdBegin!.complete();
    await finish(tester, session);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a snapshot exception does not poison the send queue', (
    tester,
  ) async {
    final session = await pump(tester);
    review.beginError = StateError('snapshot failed');
    session.send(const ComposerMessage(text: 'hello'));
    await tester.pump();
    expect(session.itemCount, greaterThan(0));
    expect(review.failure, isNotNull);
    await finish(tester, session);

    final before = session.itemCount;
    session.send(const ComposerMessage(text: 'next'));
    await tester.pump();
    expect(session.itemCount, greaterThan(before));
    await finish(tester, session);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a synchronous opener failure still lets a message go', (
    tester,
  ) async {
    final session = await pump(
      tester,
      openReview: (root, {session}) => throw StateError('open failed'),
    );
    session.send(const ComposerMessage(text: 'hello'));
    await tester.pump();
    expect(session.itemCount, greaterThan(0));
    await finish(tester, session);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('while a turn runs, the project is scanned every few seconds', (
    tester,
  ) async {
    final session = await pump(tester);
    review.holdBegin = Completer()..complete();
    session.send(const ComposerMessage(text: '改一下'));
    await tester.pump(const Duration(milliseconds: 200));
    final before = review.calls.where((call) => call == 'observe').length;

    await tester.pump(const Duration(seconds: 3));
    expect(
      review.calls.where((call) => call == 'observe').length,
      greaterThan(before),
    );

    await finish(tester, session);
    final after = review.calls.where((call) => call == 'observe').length;
    await tester.pump(const Duration(seconds: 4));
    expect(review.calls.where((call) => call == 'observe').length, after);
  });

  testWidgets('the changes, and Keep and Undo, are the review\'s', (
    tester,
  ) async {
    final session = await pump(tester);
    session.send(const ComposerMessage(text: '把输入框改成随内容增高'));
    await finish(tester, session);

    const change = FileChange(path: '/p/lib/a.dart', added: 2, removed: 1);
    review.list(const [change]);
    await tester.pump();
    expect(session.fileChanges, [change]);
    expect(find.text('1 file changed'), findsOneWidget);

    session.keepChanges(const [change]);
    session.undoChanges!(const [change]);
    session.undoAllChanges!();
    await tester.tap(find.text('Keep all'));
    expect(
      review.calls,
      containsAllInOrder([
        'keep /p/lib/a.dart',
        'undo /p/lib/a.dart',
        'undoAll',
        'keepAll',
      ]),
    );

    // Failed, it gives way to what the kernel reported.
    review.abandon('gone');
    await tester.pump();
    expect(session.fileChanges, isNot([change]));
    expect(session.undoChanges, isNull);
    await tester.pump(const Duration(seconds: 5));
  });
}
