"""Exercise full-span typo candidates with the real Rime engine and a disposable dictionary."""
import argparse
from pathlib import Path
import shutil
import tempfile
from textwrap import dedent

from rime_api import Rime
from run_real_rime import Harness, fixture_files, install

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--plugin', required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='pinyin-typo-fixture-') as temp:
        root = Path(temp)
        shared, user = root / 'shared', root / 'user'
        fixture_files(shared)
        user.mkdir()
        schema = shared / 'letter_fixture.schema.yaml'
        recipe = (ROOT / 'config/rime_ice_typo.patch.yaml').read_text()
        reference = recipe[recipe.index('  typo_reference:'):]
        schema.write_text(schema.read_text().replace('  enable_user_dict: true',
            '  user_dict: fixture_learning\n  enable_user_dict: true').replace('filters: [uniquifier]',
            'filters: ["lua_filter@*pinyin_typo_filter", "lua_filter@*learned_probe", uniquifier]') +
            '\n' + dedent(reference).replace('dictionary: rime_ice', 'dictionary: letter_fixture'))
        shutil.copy2(schema, user)
        with (shared / 'letter_fixture.dict.yaml').open('a') as words:
            # Give every first syllable a native candidate, including wrong input.
            words.write('经\tjing\t1000\n场\tchang\t1000\n仓\tcang\t1000\n仅\tjin\t1000\n'
                        '经常\tjing chang\t100000\n京仓\tjing cang\t1\n场景\tchang jing\t100000\n'
                        '人工智能\tren gong zhi neng\t100000\n人\tren\t1000\n')
        install(user, 'letter_fixture', True, keys='asdfghjkl')
        shutil.copy2(ROOT / 'lua/pinyin_typo_filter.lua', user / 'lua')
        # Inspect canonical rows only after reopening Rime against this disposable userdb.
        (user / 'lua/learned_probe.lua').write_text("""
return function(input, env)
  local ctx = env.engine.context
  if ctx:get_option("verify_learning") then
    local memory = Memory(env.engine, env.engine.schema, "translator")
    for _, code in ipairs({"jing chang", "ren gong zhi neng"}) do
      memory:user_lookup(code, false)
      for entry in memory:iter_user() do
        if entry.custom_code == code .. " " and entry.commit_count > 0 then
          ctx:set_property("learned_" .. code .. entry.text, "yes")
        end
      end
    end
    memory:disconnect()
  end
  for candidate in input:iter() do yield(candidate) end
end
""")
        engine = Rime(args.library, shared, user, [args.plugin])
        try:
            assert engine.deploy_config_file(b'default.yaml', b'config_version')
            assert engine.deploy_schema(bytes(user / schema.name))
            harness = Harness(engine)
            harness.start()
            for code in ('jincghang', 'jingcang', 'jingchhang', 'jinfchang', 'rengongnengzhi'):
                expected = '人工智能' if code == 'rengongnengzhi' else '经常'
                harness.type(code)
                _, state = harness.key('space')
                assert expected in state['candidates'][:3], (code, state)
                index = state['candidates'].index(expected)
                _, selected = harness.key('asdfghjkl'[index])
                assert selected['commit'] == expected and not selected['input'], (code, selected)
                assert not engine.property(harness.sid, '_letter_selection_learning_error')
            for code, first in [('jingchang', '经常'), ('changjing', '场景'), ('nihao', '你好')]:
                harness.type(code)
                _, state = harness.key('space')
                assert state['candidates'][0] == first, (code, state)
                engine.clear_composition(harness.sid)
            engine.destroy_session(harness.sid)
        finally:
            engine.finalize()
        engine = Rime(args.library, shared, user, [args.plugin])
        try:
            harness = Harness(engine)
            harness.start()
            engine.set_option(harness.sid, b"verify_learning", 1)
            harness.type('jing')
            for code, word in [('jing chang', '经常'), ('ren gong zhi neng', '人工智能')]:
                assert engine.property(harness.sid, 'learned_' + code + word) == 'yes', (code, word)
            engine.destroy_session(harness.sid)
        finally:
            engine.finalize()
    print('PASS: four edit types, adjacent syllable reversal, complete commits, exact first choices and canonical learning after reopening')


if __name__ == '__main__':
    main()
