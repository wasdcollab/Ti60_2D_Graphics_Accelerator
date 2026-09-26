# sw/legacy -- pre-GCC firmware flow (reference only)

These two files are the **old** firmware flow and are no longer part of the
build:

  generate_firmware.py   hand-written RV32I assembler that emitted raw machine
                         code and wrote the four BRAM byte-lane init files
  step3_vm_sim.py        strict VM regression that ran that generated image

They are kept because they are the *golden reference* for the system behaviour
(650 objects, split-screen double buffering, mode switching) and because the
BRAM lane format was reverse-engineered from them.

The supported flow is now:

    sw/build_firmware.bat          (riscv-none-elf-gcc -> ELF -> BIN -> lanes)
    simulator/test_runner.py       (runs sw/build/firmware.bin on the VM)

Do not regenerate the BRAM lane files with generate_firmware.py any more: it
would overwrite the GCC firmware image.