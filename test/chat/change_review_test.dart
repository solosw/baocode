@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart';
import 'package:baocode/chat/review/review_store_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// No snapshots are taken while testing the folder opener.
class _UnusedStore implements ReviewStore {
  _UnusedStore(this.root);

  @override
  final String root;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _DelayedStore extends _UnusedStore {
  _DelayedStore() : super('/delayed');

  final pending = Completer<String>();
  final calls = <String>[];

  @override
  Future<String> snapshot({Iterable<String>? paths}) {
    calls.add('snapshot');
    return pending.future;
  }

  @override
  Future<void> forget(String session) async => calls.add('forget');
}

class _OpeningReview extends ChangeReview {
  _OpeningReview(String root) : super(_UnusedStore(root));

  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// Runs local Git (no network) on a project in a temporary folder, its
/// snapshots in another.
void main() {
  final hasGit = () {
    try {
      return Process.runSync('git', ['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();

  late Directory temp;
  late String root;
  late String checkpoints;

  String path(String relative) => p.joinAll([root, ...relative.split('/')]);

  void write(String relative, String text) {
    final file = File(path(relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  String read(String relative) => File(path(relative)).readAsStringSync();

  Future<ChangeReview> open({String? session}) async {
    final store = await GitReviewStore.open(root, checkpoints: checkpoints);
    final review = ChangeReview(store!);
    addTearDown(review.dispose);
    if (session != null) review.session = session;
    return review;
  }

  /// The pending changes, by path relative to the project.
  Map<String, FileChange> changesOf(ChangeReview review) => {
    for (final change in review.changes)
      p.split(p.relative(change.path, from: root)).join('/'): change,
  };

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('baocode_review_');
    final resolved = await temp.resolveSymbolicLinks();
    root = p.join(resolved, 'project');
    checkpoints = p.join(resolved, 'checkpoints');
    write('a.txt', '1\n2\n3\n4\n5\n');
    write('lib/b.txt', 'b\n');
  });

  tearDown(() => temp.delete(recursive: true));

  test(
    'lists what the agent changed in a turn, not what changed before',
    () async {
      final review = await open();
      await review.begin();
      // Before the turn: not the agent's.
      write('notes.txt', 'mine\n');
      await review.begin();

      write('a.txt', 'one\n2\n3\n4\n5\n6\n');
      write('lib/c.txt', 'c\nc\n');
      File(path('lib/b.txt')).deleteSync();
      await review.observe();

      final changes = changesOf(review);
      expect(
        changes.keys,
        unorderedEquals(['a.txt', 'lib/b.txt', 'lib/c.txt']),
      );
      expect(changes['a.txt']!.kind, FileChangeKind.modified);
      expect((changes['a.txt']!.added, changes['a.txt']!.removed), (2, 1));
      expect(changes['lib/c.txt']!.kind, FileChangeKind.added);
      expect(changes['lib/c.txt']!.added, 2);
      expect(changes['lib/b.txt']!.kind, FileChangeKind.deleted);
      expect(changes['lib/b.txt']!.removed, 1);

      // Changed back by the agent: nothing pending.
      write('lib/c.txt', 'c\n');
      File(path('lib/c.txt')).deleteSync();
      await review.observe();
      expect(changesOf(review).keys, unorderedEquals(['a.txt', 'lib/b.txt']));
    },
    skip: !hasGit,
  );

  test('keeps a change without touching the file', () async {
    final review = await open();
    await review.begin();
    write('a.txt', 'one\n');
    write('lib/b.txt', 'bee\n');
    await review.observe();

    await review.keep([path('a.txt')]);
    expect(changesOf(review).keys, ['lib/b.txt']);
    expect(read('a.txt'), 'one\n');

    // Changed again by the agent: listed against what was kept.
    write('a.txt', 'one\ntwo\n');
    await review.observe();
    expect(changesOf(review)['a.txt']!.added, 1);
    expect(changesOf(review)['a.txt']!.removed, 0);

    await review.keepAll();
    expect(review.changes, isEmpty);
  }, skip: !hasGit);

  test('undoes edits, creations and deletions', () async {
    final review = await open();
    await review.begin();
    write('a.txt', 'one\n');
    write('new/deep/c.txt', 'c\n');
    File(path('lib/b.txt')).deleteSync();
    await review.observe();
    expect(review.changes, hasLength(3));

    await review.undoAll();
    expect(review.changes, isEmpty);
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');
    expect(read('lib/b.txt'), 'b\n');
    // The folders it made go with the file.
    expect(Directory(path('new')).existsSync(), isFalse);

    // Undone, it is not the agent's change.
    await review.observe();
    expect(review.changes, isEmpty);
  }, skip: !hasGit);

  test('undo keeps what changed since the agent, or leaves the file', () async {
    final review = await open();
    await review.begin();
    write('a.txt', 'one\n2\n3\n4\n5\n');
    write('lib/b.txt', 'bee\n');
    await review.observe();

    // The user, after the turn.
    write('a.txt', 'one\n2\n3\n4\nfive\n');
    write('lib/b.txt', 'B\n');
    await review.begin();

    await review.undo([path('a.txt')]);
    expect(read('a.txt'), '1\n2\n3\n4\nfive\n');
    expect(changesOf(review).keys, ['lib/b.txt']);

    // The same line: left as it is, and marked.
    await review.undo([path('lib/b.txt')]);
    expect(read('lib/b.txt'), 'B\n');
    expect(changesOf(review)['lib/b.txt']!.conflict, isTrue);
  }, skip: !hasGit);

  test('puts back line endings and bytes as they were', () async {
    write('.gitattributes', '* text=auto\n');
    File(path('crlf.txt')).writeAsBytesSync('x\r\ny\r\n'.codeUnits);
    final review = await open();
    await review.begin();
    File(path('crlf.txt')).writeAsBytesSync('x\r\nz\r\n'.codeUnits);
    await review.observe();
    await review.undoAll();
    expect(File(path('crlf.txt')).readAsBytesSync(), 'x\r\ny\r\n'.codeUnits);
  }, skip: !hasGit);

  test('lists reported edits it cannot see, to keep and not undo', () async {
    write('.gitignore', 'out/\n');
    final review = await open();
    await review.begin();
    write('out/gen.txt', 'g\n');
    review.report(FileChange(path: path('out/gen.txt'), added: 1, removed: 0));
    review.report(
      FileChange(
        path: p.join(temp.path, 'elsewhere.txt'),
        added: 2,
        removed: 0,
      ),
    );
    await review.observe(full: false);

    final changes = changesOf(review);
    expect(changes.keys, contains('out/gen.txt'));
    expect(changes['out/gen.txt']!.tracked, isFalse);
    expect(review.changes.where((c) => !c.tracked), hasLength(2));

    await review.undoAll();
    expect(File(path('out/gen.txt')).existsSync(), isTrue);
    await review.keepAll();
    expect(review.changes, isEmpty);
  }, skip: !hasGit);

  test('reported edits are looked at alone until the turn ends', () async {
    final review = await open();
    await review.begin();
    write('a.txt', 'one\n');
    write('lib/b.txt', 'bee\n');
    review.report(FileChange(path: path('a.txt'), added: 1, removed: 1));
    await review.observe(full: false);
    expect(changesOf(review).keys, ['a.txt']);
    await review.observe();
    expect(changesOf(review).keys, unorderedEquals(['a.txt', 'lib/b.txt']));
  }, skip: !hasGit);

  test('marks what changed while another agent worked there', () async {
    final mine = await open();
    final theirs = await open();
    await mine.begin();
    mine.working = true;
    theirs.working = true;
    write('a.txt', 'one\n');
    write('lib/b.txt', 'bee\n');
    mine.report(FileChange(path: path('a.txt'), added: 1, removed: 1));
    await mine.observe();
    final changes = changesOf(mine);
    expect(changes['a.txt']!.shared, isFalse);
    expect(changes['lib/b.txt']!.shared, isTrue);
  }, skip: !hasGit);

  test('carries on where the session left off', () async {
    final review = await open(session: 'session-1');
    await review.begin();
    write('a.txt', 'one\n');
    await review.observe();

    final reopened = await ChangeReview.resume(
      (await GitReviewStore.open(root, checkpoints: checkpoints))!,
      'session-1',
    );
    addTearDown(reopened.dispose);
    expect(changesOf(reopened).keys, ['a.txt']);
    await reopened.undoAll();
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');
  }, skip: !hasGit);

  test('leaves out its checkpoints where the project holds them', () async {
    // A home folder opened as the project, the data folder in it.
    checkpoints = path('.baocode-server/data/checkpoints');
    final review = await open();
    await review.begin();
    await review.begin();
    write('a.txt', 'one\n');
    await review.observe();
    expect(changesOf(review).keys, ['a.txt']);

    // Snapshots of an earlier build that took them in are let go.
    final store = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
    final repository = p.relative(store.gitDir, from: root);
    await Process.run('git', [
      '--git-dir=${store.gitDir}',
      '--work-tree=$root',
      'add',
      '-f',
      '--',
      repository,
    ], workingDirectory: root);
    final reopened = (await GitReviewStore.open(
      root,
      checkpoints: checkpoints,
    ))!;
    final before = await reopened.snapshot();
    write('lib/b.txt', 'two\n');
    final after = await reopened.snapshot();
    expect((await reopened.diff(before, after)).map((change) => change.path), [
      'lib/b.txt',
    ]);
  }, skip: !hasGit);

  testWidgets(
    'openAll isolates failed and hung folders and disposes late opens',
    (tester) async {
      final good = _OpeningReview('/good');
      final late = _OpeningReview('/hung');
      addTearDown(good.dispose);
      final hang = Completer<ChangeReview?>();
      final calls = <String>[];
      final opening = ChangeReview.openAll(
        ['/hung', '/throws', '/rejects', '/good', '/good'],
        session: 'session-1',
        openReview: (root, {session}) {
          calls.add(root);
          expect(session, 'session-1');
          return switch (root) {
            '/hung' => hang.future,
            '/throws' => throw StateError('cannot open'),
            '/rejects' => Future.error(StateError('cannot resume')),
            _ => Future.value(good),
          };
        },
      );
      await tester.pump();
      // All distinct roots open at once, even though the first is hung.
      expect(calls, ['/hung', '/throws', '/rejects', '/good']);
      await tester.pump(const Duration(seconds: 20));
      expect(await opening, same(good));
      expect(good.disposed, isFalse);

      hang.complete(late);
      await tester.pump();
      expect(late.disposed, isTrue);
    },
  );

  testWidgets('an abandoned review does not persist a late baseline', (
    tester,
  ) async {
    final store = _DelayedStore();
    final review = ChangeReview(store)..session = 'session-1';
    addTearDown(review.dispose);
    final beginning = review.begin();
    await tester.pump();
    expect(store.calls, ['snapshot']);

    review.abandon('send wait expired');
    store.pending.complete('late-tree');
    await tester.pump();
    await beginning;
    expect(store.calls, ['snapshot']);
    expect(review.changes, isEmpty);
  });

  testWidgets('openAll handles an error arriving after its timeout', (
    tester,
  ) async {
    final hang = Completer<ChangeReview?>();
    final opening = ChangeReview.openAll([
      '/hung',
    ], openReview: (root, {session}) => hang.future);
    await tester.pump(const Duration(seconds: 20));
    expect(await opening, isNull);
    hang.completeError(StateError('late open failure'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test(
    'a workspace lists a change in an added folder, not only its own',
    () async {
      final added = p.join(p.dirname(root), 'added');
      final addedCheckpoints = p.join(
        p.dirname(checkpoints),
        'added-checkpoints',
      );
      Directory(added).createSync();
      File(p.join(added, 'note.txt')).writeAsStringSync('old\n');
      final own = (await GitReviewStore.open(root, checkpoints: checkpoints))!;
      final folder = (await GitReviewStore.open(
        added,
        checkpoints: addedCheckpoints,
      ))!;
      final review = WorkspaceChangeReview.of([
        ChangeReview(own),
        ChangeReview(folder),
      ]);
      addTearDown(review.dispose);

      void timedOut() => fail('workspace review operation timed out');
      Future<void> checked(Future<void> operation) =>
          operation.timeout(const Duration(seconds: 30), onTimeout: timedOut);

      review.session = 'workspace-session';
      await checked(review.begin());
      write('a.txt', 'one\n');
      File(p.join(added, 'note.txt')).writeAsStringSync('new\n');
      await checked(review.observe());

      expect(
        review.changes.map((change) => change.path),
        unorderedEquals([path('a.txt'), p.join(added, 'note.txt')]),
      );

      await checked(review.undo([p.join(added, 'note.txt')]));
      expect(review.changes.map((change) => change.path), [path('a.txt')]);
      expect(File(p.join(added, 'note.txt')).readAsStringSync(), 'old\n');
      expect(review.failure, isNull);

      await checked(review.undoAll());
      expect(read('a.txt'), '1\n2\n3\n4\n5\n');
      expect(review.changes, isEmpty);

      write('a.txt', 'kept\n');
      await checked(review.observe());
      await checked(review.keepAll());
      expect(read('a.txt'), 'kept\n');
      expect(review.changes, isEmpty);
      await checked(review.discard());
      expect(review.failure, isNull);
    },
    skip: !hasGit,
  );

  test("leaves the project's own repository alone", () async {
    Future<String> git(List<String> arguments) async {
      final result = await Process.run(
        'git',
        arguments,
        workingDirectory: root,
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return '${result.stdout}';
    }

    await git(['init', '-q']);
    await git(['add', '-A']);
    final status = await git(['status', '--porcelain']);
    final review = await open(session: 's');
    await review.begin();
    write('a.txt', 'one\n');
    await review.observe();
    await review.undoAll();

    expect(await git(['status', '--porcelain']), status);
    expect(await git(['for-each-ref']), isEmpty);
    expect(await git(['stash', 'list']), isEmpty);
  }, skip: !hasGit);
}
