function section()
{
    printf "
=====================================================================
$*
=====================================================================\n"
}

########################################################################
# Restore backup from given directory and . If given
# multiple directories, first one is threated as base, rest as incremental.
# Synopsis:
#   restore_from <backup_dir> [<incremental_backup_dir> ...]
#########################################################################
function restore_from()
{
    local backup_path=$1
    shift 1
    stop_server
    rm -rf $mysql_datadir/*
    local extra=

    if [ "$#" -ne 0 ]
    then
        section "Preparing $backup_path as base of incremental backup"
        extra="--apply-log-only "
    else
        section "Preparing $backup_path"
    fi
    run_cmd xtrabackup --prepare $extra --target-dir=$backup_path

    while [ "$#" -ne 0 ]
    do
        incremental_dir=$1
        shift 1
        if [ "$#" -eq 0 ]
        then
            section "Last incremental $incremental_dir"
            extra=
        else
            extra='--apply-log-only'
        fi
        section "Preparing $incremental_dir as incremental"
        run_cmd xtrabackup --prepare $extra\
           --target-dir=$backup_path --incremental-dir=$incremental_dir
    done

    run_cmd xtrabackup --copy-back --target-dir=$backup_path
    start_server
}

function test_backup_with_custom_read_buffer()
{
    local buffer_size=$1
    local backup_dest=$topdir/backup_${buffer_size}
    local backup_dest_base=$topdir/backup_${buffer_size}_base
    local backup_dest_inc=$topdir/backup_${buffer_size}_inc

    section "$buffer_size buffer size"
    section "Regular backup."
    xtrabackup --backup --target-dir=$backup_dest \
#        --read_buffer_size=$buffer_size

    mkdir $backup_dest_base
    cp -r $backup_dest/* $backup_dest_base

    section "Restoring."
    restore_from $backup_dest

    section "Verifying."
    verify_db_state incremental_sample

    section "Inserting more data into table"
    multi_row_insert incremental_sample.test \({1000..1500},200\)
    record_db_state incremental_sample

    section "Incremental backup."
    xtrabackup --backup \
        --incremental-basedir=$backup_dest_base \
        --target-dir=$backup_dest_inc

    section "Restoring incremental."
    restore_from $backup_dest $backup_dest_inc

    section "Verifying incremental."
    verify_db_state incremental_sample

    vlog "Done."
}

start_server

load_dbase_schema incremental_sample
multi_row_insert incremental_sample.test \({1..999},100\)

section "Creating a MyISAM-powered clone of the incremental_sample.test"
mysql -e "show create table incremental_sample.test;" \
    | tail -n +2 \
    | sed -r 's/test\s+CREATE TABLE `test`/CREATE TABLE `test_MyISAM`/' \
    | sed 's/ENGINE=InnoDB/ENGINE=MyISAM/' \
    > $topdir/test_myISAM.sql

mysql incremental_sample <<EOF
$(cat $topdir/test_myISAM.sql);
insert into test_MyISAM select * from test;
EOF

record_db_state incremental_sample

test_backup_with_custom_read_buffer 1Kb

section "Reverting server to original state"

#mysql incremental_sample -e "TRUNCATE test; TRUNCATE test_MyISAM;"
#restore_db_state incremental_sample
mysql -e "delete from incremental_sample.test where a >= 1000"

test_backup_with_custom_read_buffer 50Mb
