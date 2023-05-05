#!/usr/bin/env /data/Software/mydan/python3/bin/python3
# -*- coding: utf-8 -*-

import os
import sys
import time
import urllib.request
import subprocess
import json


def print_c3debug1_log(msg):
    if "C3DEBUG1" in os.environ:
        print(msg, file=sys.stderr)


def print_c3debug2_log(msg):
    if "C3DEBUG2" in os.environ:
        print(msg, file=sys.stderr)


def redownload_file_if_need(filepath, url, alive_seconds):
    """
        该方法会把下载的文件缓存在filepath, 超过有效期重新下载
    """
    os.makedirs(os.path.dirname(filepath), exist_ok=True)

    need_download = False
    if os.path.exists(filepath):
        modified_time=os.path.getmtime(filepath)
        if time.time()-modified_time > alive_seconds: 
            os.remove(filepath)
            need_download = True
    else:
        need_download = True

    if need_download: 
        urllib.request.urlretrieve(url, filepath)


def sleep_time_for_limiting(max_frequency_one_second):
    """
        max_frequency_one_second是某个接口每秒的最大请求频率,
        该接口的作用是根据频率限制因子限制频率
    """
    frequency_factor = float(get_frequency_factor())
    if frequency_factor < 0:
        frequency_factor = 0
    if frequency_factor > 1:
        frequency_factor = 1
    
    sleep_second = 0
    
    # 取0表示按照max_frequency_one_second的频率执行
    if frequency_factor == 0:
        # 因为没法预知一个接口请求一次花的时间, 并且如果请求海外服务
        # 响应会更慢, 这里只能预估一个响应时间, 假设一次请求往返消耗0.08秒
        assume_resp_time = 0.08
        all_resp_time = assume_resp_time * max_frequency_one_second
        if all_resp_time > 1:
            # 预估的时间肯定不准确, 但还是要保证能休眠一小段时间
            all_resp_time = 0.8
        sleep_second = (1 - all_resp_time) / (max_frequency_one_second - 1)
    elif frequency_factor == 1:
        sleep_second = (max_frequency_one_second - 1) / max_frequency_one_second
    else:
        sleep_second = frequency_factor
    
    time.sleep(sleep_second)
    return


# 获取同步频率限制因子
# 改因子最小为0，最大为1
def get_frequency_factor():
    output = subprocess.getoutput("c3mc-sys-ctl sys.device.sync.frequency.factor")
    return output


def check_if_params_safe_in_recycle(user_commited_instance_ids, bpm_uuid, bpm_action_type):
    """检查资源回收中涉及的参数是否合法
    """
    cmd_parts = ["c3mc-bpm-protect", "--eventname", bpm_action_type, "--bpmuuid", bpm_uuid]

    proc = subprocess.Popen(cmd_parts, stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    for instance_id in user_commited_instance_ids:
        proc.stdin.write(instance_id.encode())
        proc.stdin.write(b"\n")
        proc.stdin.flush()

    output, errors = proc.communicate()
    if output is not None:
        print(f"命令 c3mc-bpm-protect 执行结果: {output.decode()}")
    if errors is not None:
        print(f"命令 c3mc-bpm-protect 执行出现错误: {errors.decode()}", file=sys.stderr)

    if proc.returncode == 1:
        print("命令 c3mc-bpm-protect 执行出现错误, 直接退出", file=sys.stderr)
        exit(1)

    if proc.returncode == 254:
        # 用户拒绝继续操作，直接退出程序
        print("用户拒绝继续操作，直接退出程序")
        exit(0)

# 下面的 decode_for_special_symbol 和 encode_for_special_symbol 
# 用于实现 bpm目录下 `special_encoding.md` 文件中编码规则的编码和解码
# 
# 下面代码仅处理 ASCII 中的特殊字符（非字母数字字符），而不处理其他 Unicode 字符
def decode_for_special_symbol(encoded_str):
    decoded_str = ''
    i = 0
    while i < len(encoded_str):
        if encoded_str[i] == 'E':
            temp = ''
            i += 1
            while i < len(encoded_str) and encoded_str[i] != 'E':
                temp += encoded_str[i]
                i += 1
            if i < len(encoded_str) and encoded_str[i] == 'E':
                if temp.isdigit() and 0 <= int(temp) < 128:
                    decoded_str += chr(int(temp))
                    i += 1
                else:
                    decoded_str += f'E{temp}'
            else:
                decoded_str += f'E{temp}'
        else:
            decoded_str += encoded_str[i]
            i += 1

    return decoded_str


def encode_for_special_symbol(decoded_str):
    return ''.join(
        char if char.isalnum() or ord(char) >= 128 else f'E{ord(char)}E' for char in decoded_str
    )


def bpm_merge_user_input_tags(
        instance_params, 
        tag_field_name, 
        product_owner_key_name, 
        ops_owner_key_name, 
        department_key_name,
        tag_key_field,
        tag_value_field,
    ):
    """将用户填写的业务负责人、运维负责人和其他标签合并在一起
    """
    tag_list = []
    # 检查用户是否配置了标签
    if instance_params[tag_field_name] not in [None, ""]:
        tag_list = json.loads(instance_params[tag_field_name])

    tag_name_dict = { tag[tag_key_field].lower() for tag in tag_list }
    product_owner_env_vlaue = subprocess.getoutput("c3mc-sys-ctl cmdb.tags.ProductOwner")
    ops_owner_env_value = subprocess.getoutput("c3mc-sys-ctl cmdb.tags.OpsOwner")
    department_env_value = subprocess.getoutput("c3mc-sys-ctl cmdb.tags.Department")

    if product_owner_env_vlaue.lower() not in tag_name_dict:
        tag_list.append({
            tag_key_field: product_owner_env_vlaue,
            tag_value_field: instance_params[product_owner_key_name]
        })
    if ops_owner_env_value.lower() not in tag_name_dict:
        tag_list.append({
            tag_key_field: ops_owner_env_value,
            tag_value_field: instance_params[ops_owner_key_name]
        })
    if department_env_value.lower() not in tag_name_dict:
        tag_list.append({
            tag_key_field: department_env_value,
            tag_value_field: instance_params[department_key_name]
        })
    instance_params[tag_field_name] = json.dumps(tag_list)
    return instance_params
