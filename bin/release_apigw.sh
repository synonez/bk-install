#!/usr/bin/env bash
# 用途： 更新蓝鲸的网关

# 安全模式
set -euo pipefail 

# 重置PATH
PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# 通用脚本框架变量
PROGRAM=$(basename "$0")
VERSION=1.0
EXITCODE=0

# 全局默认变量
SELF_DIR=$(dirname "$(readlink -f "$0")")

declare -a UPDATE_MODULE=(
    dashboard
    dashboard-fe
    api-support-fe
    operator
    apigateway
    bk-esb
    apigateway-core-api
)

MODULE=bk_apigateway
# 模块安装后所在的上一级目录
PREFIX=/data/bkee
# 蓝鲸产品包解压后存放的默认目录
MODULE_SRC_DIR=/data/src
# 渲染配置文件用的脚本
RENDER_TPL=${SELF_DIR}/render_tpl
# 渲染配置用的环境变量文件
ENV_FILE=${SELF_DIR}/04-final/bkapigw.env
# 如果使用tgz来更新，则从该目录来找tgz文件
RELEASE_DIR=/data/release
# 如果使用tgz来更新，该文件的文件名
TGZ_NAME=
# 备份目录
BACKUP_DIR=/data/src/backup
# 是否需要render配置文件
UPDATE_CONFIG=
# 更新模式（tgz|src）
RELEASE_TYPE=
# PYTHON目录
PYTHON_PATH=/opt/py36_e/bin/python3.6

usage () {
    cat <<EOF
用法: 
    $PROGRAM [ -h --help -?  查看帮助 ]
    通用参数：
            [ -p, --prefix          [可选] "安装的目标路径，默认为${PREFIX}" ]
            [ -r, --render-file     [可选] "渲染蓝鲸配置的脚本路径。默认是$RENDER_TPL" ]
            [ -e, --env-file        [可选] "渲染配置文件时，使用该配置文件中定义的变量值来渲染" ]
            [ -u, --update-config   [可选] "是否更新配置文件，默认不更新。" ]
            [ -B, --backup-dir      [可选] "备份程序的目录，默认是$BACKUP_DIR" ]
            [ -v, --version         [可选] "脚本版本号" ]
            [ -P, --python-path     [可选] "指定创建virtualenv时的python二进制路径，默认为$PYTHON_PATH" ]

    更新模式有两种:
    1. 使用tgz包更新，则需要指定以下参数：
            [ -d, --release-dir     [可选] "$MODULE安装包存放目录，默认是$RELEASE_DIR" ]
            [ -f, --filename        [必选] "安装包名，不带路径" ]
    
    2. 使用中控机解压后的$MODULE_SRC_DIR/{module} 来更新: 需要指定以下参数
            [ -s, --srcdir      [可选] "从该目录拷贝$MODULE/目录到--prefix指定的目录" ]
    
    如果以上三个参数都指定了，会以tgz包的参数优先使用，忽略-s指定的目录
EOF
}

usage_and_exit () {
    usage
    exit "$1"
}

log () {
    echo "$@"
}

error () {
    echo "$@" 1>&2
    usage_and_exit 1
}

warning () {
    echo "$@" 1>&2
    EXITCODE=$((EXITCODE + 1))
}

version () {
    echo "$PROGRAM version $VERSION"
}

# 解析命令行参数，长短混合模式
(( $# == 0 )) && usage_and_exit 1
while (( $# > 0 )); do 
    case "$1" in
        -p | --prefix )
            shift
            PREFIX=$1
            ;;
        -e | --env-file )
            shift
            ENV_FILE="$1"
            ;;
        -r | --render-file )
            shift
            RENDER_TPL=$1
            ;;
        -u | --update-config )
            UPDATE_CONFIG=1
            ;;
        -B | --backup-dir)
            shift
            BACKUP_DIR=$1
            ;;
        -d | --release-dir)
            shift
            RELEASE_DIR=$1
            ;;
        -f | --filename)
            shift
            TGZ_NAME=$1
            ;;
        -s | --srcdir )
            shift
            MODULE_SRC_DIR=$1
            ;;
        -P | --python-path )
            shift
            PYTHON_PATH=$1
            ;;
        --help | -h | '-?' )
            usage_and_exit 0
            ;;
        --version | -v | -V )
            version 
            exit 0
            ;;
        -*)
            error "不可识别的参数: $1"
            ;;
        *) 
            break
            ;;
    esac
    shift $(($# == 0 ? 0 : 1))
done 

check_exists () {
    local file=$1
    if ! [[ -e "$file" ]]; then
        warning "$file is not exists. please check"
    fi
}

is_string_in_array() {
    local e
    for e in "${@:2}"; do
        [[ "$e" == "$1" ]] && return 0
    done
    return 1
}

# 首先需要确定是哪种模式更新
if [[ -n "$TGZ_NAME" ]]; then
    # 如果确定 $TGZ_NAME 变量，那么无论如何都优先用tgz包模式更新
    RELEASE_TYPE=tgz
    TGZ_NAME=${TGZ_NAME##*/}    # 兼容传入带前缀路径的包名
    TGZ_PATH=${RELEASE_DIR}/$TGZ_NAME
else
    RELEASE_TYPE=src
fi

### 文件/文件夹是否存在判断
# 通用的变量
for f in "$PREFIX" "$BACKUP_DIR"; do 
    check_exists "$f"
done
if [[ $UPDATE_CONFIG -eq 1 ]]; then 
    for f in "$RENDER_TPL" "$ENV_FILE"; do
        check_exists "$f"
    done
fi
# 不同release模式的差异判断
if [[ $RELEASE_TYPE = tgz ]]; then 
    check_exists "$TGZ_PATH"
else
    check_exists "$MODULE_SRC_DIR"/$MODULE 
fi
if (( EXITCODE > 0 )); then
    usage_and_exit "$EXITCODE"
fi

# 备份老的包，并解压新的
tar -czf "$BACKUP_DIR/bkapigateway_$(date +%Y%m%d_%H%M).tgz" -C "$PREFIX" bk_apigateway etc/supervisor-bk_apigateway.conf etc/bk_apigateway/bk_apigateway.env

# 更新文件（因为是python的包，用--delete为了删除一些pyc的缓存文件）
if [[ $RELEASE_TYPE = tgz ]]; then
    # 创建临时目录
    TMP_DIR=$(mktemp -d /tmp/bkrelease_${MODULE}_XXXXXX)
    trap 'rm -rf $TMP_DIR' EXIT

    log "extract $TGZ_PATH to $TMP_DIR"
    tar -xf "$TGZ_PATH" -C "$TMP_DIR"/
    # 更新全局文件
    log "updating 全局文件 ..."
    rsync -a --delete "${TMP_DIR}/bk_apigateway/" "$PREFIX/bk_apigateway/"
else
    rsync -a --delete "${MODULE_SRC_DIR}/bk_apigateway/" "$PREFIX/bk_apigateway/"
fi

# 渲染配置文件
$RENDER_TPL -u -m "$MODULE" -p "$PREFIX" \
-e "$ENV_FILE" \
"$MODULE_SRC_DIR"/$MODULE/support-files/templates/*

# 安装虚拟环境和pip包
for APIGW_MODULE in ${UPDATE_MODULE[@]}; do
case $APIGW_MODULE in
    bk-esb|dashboard)
        # 安装虚拟环境和依赖包(使用加密解释器)
        "${SELF_DIR}"/install_py_venv_pkgs.sh -e -p "$PYTHON_PATH" \
        -n "apigw-${APIGW_MODULE}" \
        -w "${PREFIX}/.envs" -a "$PREFIX/$MODULE/${APIGW_MODULE}" \
        -s "${PREFIX}/$MODULE/support-files/pkgs" \
        -r "${PREFIX}/$MODULE/${APIGW_MODULE}/requirements.txt"

        if [[ "$PYTHON_PATH" = *_e* ]]; then
            # 拷贝加密解释器 //todo
            cp -a "${PYTHON_PATH}"_e "$PREFIX/.envs/apigw-${APIGW_MODULE}/bin/python"
        fi

        # migration
        (
            set +u +e
            export BK_FILE_PATH="$PREFIX"/$MODULE/cert/saas_priv.txt
            export BKPAAS_ENVIRONMENT="env"
            export BK_HOME=$PREFIX

            cd "$PREFIX"/$MODULE/"$APIGW_MODULE"/
            PATH=/$PREFIX/.envs/apigw-${APIGW_MODULE}/bin:$PATH \
            bash ./bin/on_migrate
        )

        if [[ $? -ne 0 ]]; then
            fail "bk_apigw($APIGW_MODULE) migrate failed"
        fi
    ;;
    *)
        echo "unknown $APIGW_MODULE"
        ;;
esac
done

# 修改权限
chown -R blueking.blueking "$PREFIX/$MODULE"
chmod 755 "$PREFIX"/$MODULE/*/*.sh

# 重启进程
/opt/py36/bin/supervisorctl -c "$PREFIX"/etc/supervisor-bk_apigateway.conf reload
systemctl restart apisix.service

#检查本次更新的模块启动是否正常
CHECK_MODULE=(bk-apigw.service apisix.service)
running_status=()
for m in "${CHECK_MODULE[@]}"; do
    running_status+=( "$(systemctl show -p SubState,MainPID,Names "$m" | awk -F= '{print $2}'  | xargs)" )
done

printf "%s\n" "${running_status[@]}"

if [[ $(printf "%s\n" "${running_status[@]}" | grep -c running) -ne ${#CHECK_MODULE[@]} ]]; then
    log "启动成功的进程数量少于更新的模块数量"
    exit 1
else
    log "启动成功的进程数量和更新的模块数量一致"
fi
