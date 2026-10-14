"""Bundle pinyin defaults without writing any user settings or Rime data."""
from pathlib import Path
import argparse
import shutil

ROOT = Path(__file__).resolve().parents[1]
RESOURCE = Path('enhanced-squirrel/resources/DefaultLetterSelection')


def verify_bundle(app, root=ROOT):
    source = root / RESOURCE / 'luna_pinyin.custom.yaml'
    for target in [app / 'Contents/SharedSupport/luna_pinyin.custom.yaml',
                   app / 'Contents/Resources/DefaultLetterSelection/luna_pinyin.custom.yaml']:
        assert target.is_file() and not target.is_symlink()
        assert target.read_bytes() == source.read_bytes(), 'Default letter patch mismatch'
    lua = app / 'Contents/SharedSupport/lua/letter_selection.lua'
    assert lua.is_file() and not lua.is_symlink()
    assert lua.read_bytes() == (root / 'enhanced-squirrel/resources/letter_selection.lua').read_bytes()


def bundle(app, root=ROOT):
    assert app.is_dir() and not app.is_symlink()
    for destination in ['SharedSupport/luna_pinyin.custom.yaml',
                        'Resources/DefaultLetterSelection/luna_pinyin.custom.yaml']:
        target = app / 'Contents' / destination
        target.parent.mkdir(parents=True, exist_ok=True)
        assert not target.is_symlink()
        shutil.copyfile(root / RESOURCE / 'luna_pinyin.custom.yaml', target)
    lua = app / 'Contents/SharedSupport/lua/letter_selection.lua'
    lua.parent.mkdir(parents=True, exist_ok=True)
    assert not lua.is_symlink()
    shutil.copyfile(root / 'enhanced-squirrel/resources/letter_selection.lua', lua)
    verify_bundle(app, root)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    bundle(parser.parse_args().app.resolve())
    print('PASS: default letters bundled; user directories untouched')
