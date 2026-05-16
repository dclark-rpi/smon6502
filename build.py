from rp6502_sdk import rp6502
import subprocess

# Name of vasm source to compile
src_code = 'src/smon.asm'

# Name of the vasm output file
bin_6502 = 'smon'

# Name of the RP6502 Picocomputer ROM
rom_rp6502 = 'smon.rp6502'

# Start address of the executable - must match .org in src_code
address = 0xD000

def compile() -> subprocess.CompletedProcess:
    compile_cmd = [
        'vasm6502_oldstyle',
        '-Fbin',
        '-esc',
        '-dotdir',
        '-c02',
        '-o', bin_6502,
        src_code
    ]
    cp = subprocess.run(compile_cmd)
    if cp.returncode != 0:
        sys.exit(cp.returncode)

def build_rp6502():
    rom = rp6502.ROM()
    rom.comment('System Monitor')
    rom.binary_file(bin_6502, address)
    rom.reset_vector()

    with open(rom_rp6502, 'wb') as o:
        rom.seek(0)
        while True:
            chunk = rom.read(1024)
            if len(chunk) == 0:
                break
            o.write(chunk)

if __name__ == '__main__':
    compile()
    build_rp6502()
