import 'package:baocode/ide/git/git_model.dart';
import 'package:baocode/ide/git/scm_tree.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a remote slash path stays a tree on Windows path rules', () {
    final tree = ideScmTree('/sessions', [
      const IdeGitResource(
        path: '/sessions/lib/main.dart',
        status: IdeGitStatus.modified,
        group: IdeGitGroup.workingTree,
      ),
    ]);
    expect(tree, hasLength(1));
    final folder = tree.single as IdeScmTreeFolder;
    expect(folder.label, 'lib');
    expect((folder.children.single as IdeScmTreeFile).resource.path,
        '/sessions/lib/main.dart');
  });
}
