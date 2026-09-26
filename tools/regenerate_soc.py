#!/usr/bin/env python
"""Regenerate the existing Sapphire SoC IP from its checked-in settings.json.

Run this through regenerate_soc.bat so the Efinity Python and IP Manager
environment are configured correctly.
"""
from pathlib import Path
import os
import sys


ROOT = Path(__file__).resolve().parents[1]
EFINITY_HOME = Path(os.environ["EFINITY_HOME"])
IPM_BIN = EFINITY_HOME / "ipm" / "bin"
sys.path.insert(0, str(IPM_BIN))
sys.path.insert(0, str(IPM_BIN / "rpc"))

from efx_ipmgr.api_v2 import IPGenerationSetting  # noqa: E402
from efx_ipmgr.production_api.type.vlnv_type import VLNV  # noqa: E402
from gui import api_wrapper  # noqa: E402
from gui.enums import OOC_Syn_Opt  # noqa: E402


def main():
    settings = ROOT / "ip" / "soc" / "settings.json"
    setting = IPGenerationSetting.load(settings)
    vlnv = VLNV(
        vendor=setting.vlnv.vendor,
        library=setting.vlnv.library,
        name=setting.vlnv.name,
        version=setting.vlnv.version,
    )
    api_wrapper.refresh_api_option()
    matches, _ = api_wrapper.get_list_of_ips(
        vendor=vlnv.vendor,
        library=vlnv.library,
        name=vlnv.name,
        device_name="Ti60F225",
        family_name="Titanium",
        should_log=False,
    )
    print("available:", ", ".join(str(item) for item in matches))
    if not matches:
        raise RuntimeError("no compatible Sapphire SoC IP found")
    if vlnv not in matches:
        target = matches[-1]
        print("upgrading:", vlnv, "->", target)
        result = api_wrapper.upgrade_ip(
            target_vlnv=target,
            setting_path=settings,
            out_path=ROOT,
            device="Ti60F225",
            family="Titanium",
            peri_xml_file_path=ROOT / "ti60_top.peri.xml",
            project_xml_path=ROOT / "ti60_top.xml",
            postmap_module_enable="false",
            ooc_synthesis_option=OOC_Syn_Opt.DEFAULT.value,
            ooc_synthesis_custom_command="",
        )
        print(result)
        code = result[0] if isinstance(result, tuple) else result
        return 0 if code == api_wrapper.ResultCode.SUCCESS else 1
    loaded = api_wrapper.refresh_ip_sources(
        opt=None,
        vlnv=vlnv,
        project_ipm_path=settings.parent / "ipm",
        device="Ti60F225",
        family="Titanium",
    )
    params = setting.get_formatted_params(
        api_wrapper.get_ip_params(vlnv=vlnv), api_wrapper.get_option()
    )
    outputs = setting.get_formatted_outputs()
    result = api_wrapper.generate_ip(
        vlnv=vlnv,
        params=params,
        filesets=outputs,
        out_path=ROOT,
        user_ip_path=ROOT,
        gen_name=setting.gen_name,
        device_name="Ti60F225",
        family_name="Titanium",
        setting_path=settings,
        skip_put_params=False,  # apply settings.json edits, not the cached IP graph
        project_name="ti60_top",
        peri_xml_file_path=ROOT / "ti60_top.peri.xml",
        project_xml_path=ROOT / "ti60_top.xml",
        postmap_module_enable="false",
        ooc_synthesis_option=OOC_Syn_Opt.DEFAULT.value,
        ooc_synthesis_custom_command="",
    )
    print(result)
    return 0 if result == api_wrapper.ResultCode.SUCCESS else 1


if __name__ == "__main__":
    raise SystemExit(main())
