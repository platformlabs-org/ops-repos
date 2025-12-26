import json
import re
import os

def format_binary(hex_str):
    """将十六进制长字符串格式化为 INF 标准的逗号分隔字节"""
    clean_hex = hex_str.replace(" ", "").replace("0x", "")
    return ", ".join([clean_hex[i:i+2] for i in range(0, len(clean_hex), 2)])

def identify_inf_type(content):
    """根据 CatalogFile 自动判断 INF 类型"""
    if "npu_extension.cat" in content.lower():
        return "npu.extension", "NPU Extension"
    elif "extinf_i.cat" in content.lower():
        return "gfx.extension", "GFX Extension"
    elif "igdlh.cat" in content.lower():
        return "gfx.base", "GFX Base"
    return None, "Unknown"

def process_inf(inf_content, project_config, comp_path):
    lines = inf_content.splitlines()
    output = []
    current_section = ""
    
    # 动态获取 JSON 节点 (支持 npu.extension 这种嵌套路径)
    target_config = project_config
    for key in comp_path.split('.'):
        target_config = target_config.get(key, {})

    dev_ids = target_config.get("dev_id", [])
    subsys_ids = target_config.get("subsys_id", [])
    ext_id = target_config.get("extension_id", None)
    reg_funcs = target_config.get("register_function", {})

    # 匹配安装节的正则表达式
    install_section_patterns = [r"PTL_.*IG$", r"NPU_.*_Install$", r"PTL_IG$"]

    for line in lines:
        stripped = line.strip()
        
        # 识别 Section
        if stripped.startswith("[") and stripped.endswith("]"):
            current_section = stripped[1:-1].split()[0]

        # 1. 替换 ExtensionId (仅限 Extension 类型)
        if current_section == "Version" and "ExtensionId" in line and ext_id:
            output.append(f"ExtensionId = {{{ext_id}}}")
            continue

        # 2. 替换 Hardware ID (SUBSYS 替换逻辑)
        if "PCI\\VEN_8086&DEV_" in line:
            matched = False
            for d_id in dev_ids:
                # 如果 dev_id 为空字符串则匹配所有行，否则匹配特定 DEV_XXXX
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

        # 3. 注入 AddReg 引用 (在安装节末尾注入)
        is_install_sec = any(re.match(p, current_section) for p in install_section_patterns)
        if is_install_sec and stripped == "" and reg_funcs:
            for f_name in reg_funcs.keys():
                output.append(f"AddReg = {f_name}")

        output.append(line)

    # 4. 追加注册表定义块
    if reg_funcs:
        output.append("\n; --- Generated Registry Sections ---")
        for f_name, items in reg_funcs.items():
            output.append(f"[{f_name}]")
            for key, val_type, value in items:
                reg_type = "%REG_DWORD%" if val_type == "d" else "%REG_BINARY%"
                # 处理二进制格式化
                final_val = format_binary(str(value)) if val_type == "b" else str(value)
                output.append(f"HKR,, {key}, {reg_type}, {final_val}")
            output.append("")

    return "\n".join(output)

def main():
    print("=== INF 智能自动化替换工具 v2.0 ===")
    
    # 1. 加载配置
    config_path = "config.json"
    if not os.path.exists(config_path):
        print(f"错误: 在脚本目录下找不到 {config_path}")
        return
    
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config_data = json.load(f)
    except Exception as e:
        print(f"JSON 格式错误: {e}")
        return

    # 2. 用户输入项目
    project = input("请输入项目名称 (如 chogori, kailash): ").strip()
    if project not in config_data["project"]:
        print(f"错误: 项目 '{project}' 在 JSON 中不存在")
        return

    # 3. 输入 INF 路径
    inf_path = input("请拖入或输入原 INF 文件路径: ").strip().strip('"')
    if not os.path.exists(inf_path):
        print("错误: 文件不存在")
        return

    # 4. 读取内容 (尝试多种编码)
    content = ""
    for enc in ['utf-16', 'utf-8-sig', 'utf-8', 'gbk']:
        try:
            with open(inf_path, 'r', encoding=enc) as f:
                content = f.read()
                break
        except: continue
    
    if not content:
        print("错误: 无法读取文件内容")
        return

    # 5. 自动判断类型
    comp_path, type_name = identify_inf_type(content)
    if not comp_path:
        print("错误: 无法通过 CatalogFile 识别 INF 类型 (npu/gfx-ext/gfx-base)")
        return
    print(f"检测到 INF 类型: {type_name} (映射路径: {comp_path})")

    # 6. 执行处理
    try:
        updated_content = process_inf(content, config_data["project"][project], comp_path)
        
        # 7. 保存文件
        new_filename = "updated_" + os.path.basename(inf_path)
        # 驱动文件通常建议保存为 utf-8 带 BOM 或 utf-16
        with open(new_filename, 'w', encoding='utf-16') as f:
            f.write(updated_content)
        
        print(f"\n[成功] 处理完成！")
        print(f"输出文件: {os.path.abspath(new_filename)}")
        print(f"注意: 已自动将编码转换为 UTF-16 (Windows 驱动标准格式)")

    except Exception as e:
        print(f"处理过程中出错: {e}")

if __name__ == "__main__":
    main()