import json
import re
import os

def format_binary(hex_str):
    """Formats hex string to INF standard comma-separated bytes."""
    clean_hex = hex_str.replace(" ", "").replace("0x", "")
    return ", ".join([clean_hex[i:i+2] for i in range(0, len(clean_hex), 2)])

def identify_inf_type(content):
    """Identifies INF type based on CatalogFile."""
    if "npu_extension.cat" in content.lower():
        return "npu.extension", "NPU Extension"
    elif "extinf_i.cat" in content.lower():
        return "gfx.extension", "GFX Extension"
    elif "igdlh.cat" in content.lower():
        return "gfx.base", "GFX Base"
    return None, "Unknown"

def process_inf_content(inf_content, project_config, comp_path):
    lines = inf_content.splitlines()
    output = []
    current_section = ""

    # Dynamic JSON node traversal
    target_config = project_config
    for key in comp_path.split('.'):
        target_config = target_config.get(key, {})

    dev_ids = target_config.get("dev_id", [])
    subsys_ids = target_config.get("subsys_id", [])
    ext_id = target_config.get("extension_id", None)
    reg_funcs = target_config.get("register_function", {})

    # Install section patterns
    install_section_patterns = [r"PTL_.*IG$", r"NPU_.*_Install$", r"PTL_IG$"]

    for line in lines:
        stripped = line.strip()

        # Identify Section
        if stripped.startswith("[") and stripped.endswith("]"):
            current_section = stripped[1:-1].split()[0]

        # 1. Replace ExtensionId
        if current_section == "Version" and "ExtensionId" in line and ext_id:
            output.append(f"ExtensionId = {{{ext_id}}}")
            continue

        # 2. Replace Hardware ID (SUBSYS)
        if "PCI\\VEN_8086&DEV_" in line:
            matched = False
            for d_id in dev_ids:
                # If dev_id is empty, match all. Else match specific DEV_XXXX
                if d_id == "" or f"DEV_{d_id}" in line:
                    for s_id in subsys_ids:
                        if "SUBSYS_" in line:
                            new_line = re.sub(r"SUBSYS_[a-zA-Z0-9]+", f"SUBSYS_{s_id}", line)
                        else:
                            new_line = line.rstrip() + f"&SUBSYS_{s_id}"
                        output.append(new_line)
                    matched = True
                    break
            if matched: continue

        # 3. Inject AddReg reference
        is_install_sec = any(re.match(p, current_section) for p in install_section_patterns)
        if is_install_sec and stripped == "" and reg_funcs:
            for f_name in reg_funcs.keys():
                output.append(f"AddReg = {f_name}")

        output.append(line)

    # 4. Append Registry Sections
    if reg_funcs:
        output.append("\n; --- Generated Registry Sections ---")
        for f_name, items in reg_funcs.items():
            output.append(f"[{f_name}]")
            for key, val_type, value in items:
                reg_type = "%REG_DWORD%" if val_type == "d" else "%REG_BINARY%"
                final_val = format_binary(str(value)) if val_type == "b" else str(value)
                output.append(f"HKR,, {key}, {reg_type}, {final_val}")
            output.append("")

    return "\n".join(output)

def process_inf_file(inf_path, project_name, config_path):
    print(f"[InfPatcher] Processing {inf_path} for project {project_name}")

    if not os.path.exists(config_path):
        raise FileNotFoundError(f"Config not found: {config_path}")

    with open(config_path, 'r', encoding='utf-8') as f:
        config_data = json.load(f)

    if project_name not in config_data["project"]:
        raise ValueError(f"Project '{project_name}' not in config.json")

    # Read content
    content = ""
    for enc in ['utf-16', 'utf-8-sig', 'utf-8', 'gbk']:
        try:
            with open(inf_path, 'r', encoding=enc) as f:
                content = f.read()
                break
        except: continue

    if not content:
        raise ValueError("Unable to read INF file content (unknown encoding?)")

    # Identify Type
    comp_path, type_name = identify_inf_type(content)
    if not comp_path:
        raise ValueError("Could not identify INF type from CatalogFile.")
    print(f"[InfPatcher] Detected Type: {type_name} ({comp_path})")

    # Process
    updated_content = process_inf_content(content, config_data["project"][project_name], comp_path)

    # Save (Overwrite or new file? Requirement says 'need to cover original file' -> overwrite)
    # But usually writing to utf-16 with BOM is safe for INF.
    # The requirement says "need to cover original file" (cover usually means overwrite).
    with open(inf_path, 'w', encoding='utf-16') as f:
        f.write(updated_content)

    print(f"[InfPatcher] Success. Overwrote {inf_path}")
    return True

# Helper for direct execution if needed
def main():
    pass

if __name__ == "__main__":
    main()
