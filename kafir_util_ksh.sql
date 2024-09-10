create or replace package kafir_util is

  -- ===============================================================================================================================================================

	c_package_name constant varchar2(30) := 'KAFIR_UTIL';

  -- ===============================================================================================================================================================

	function convert_to_date (
		p_high_value in varchar2
	) return date;

  -- ===============================================================================================================================================================

	procedure gather_stat;

  -- ===============================================================================================================================================================

	procedure maintain_data (
		p_max_partitons_to_drop in number
	);

  -- ===============================================================================================================================================================

	procedure start_maintain;

  -- ===============================================================================================================================================================

	procedure create_range_tab_parts;

  -- ===============================================================================================================================================================

	procedure rename_partitions;

  -- ===============================================================================================================================================================

	procedure fill_kkep_report_portal (
		p_days   in number,
		p_offset in number
	);
  
  -- ===============================================================================================================================================================

	procedure ksh_report (
		p_days      in number,
		p_offset    in number,
		p_directory in varchar,
		p_portals   in varchar2
	);

 -- ===============================================================================================================================================================

	procedure vh_measures_report (
		p_month_offset in number,
		p_directory    in varchar
	);

  -- ===============================================================================================================================================================

	procedure vh_measures_aggregated_report (
		p_month_offset in number,
		p_directory    in varchar
	);

  -- ===============================================================================================================================================================

	procedure vh_upload_summary_report (
		p_month_offset in number,
		p_directory    in varchar
	);

  -- ===============================================================================================================================================================

	procedure maintain_database_tables;
  
  -- ===============================================================================================================================================================

	procedure maintain_table (
		p_table_name in varchar2
	);
  
  -- ===============================================================================================================================================================

	procedure shrink_table (
		p_table_name in varchar2
	);
  
  -- ===============================================================================================================================================================

	procedure shrink_partition (
		p_table_name     in varchar2,
		p_partition_name in varchar2
	);
  
   -- ===============================================================================================================================================================

	procedure rebuild_table_indicies (
		p_table_name in varchar2
	);
  
  -- ===============================================================================================================================================================

	procedure rebuild_partition_indicies (
		p_table_name     in varchar2,
		p_partition_name in varchar2
	);
  
  -- ===============================================================================================================================================================

	procedure modify_row_movement (
		p_table_name   in varchar2,
		p_row_movement in varchar2
	);  
 
   -- ===============================================================================================================================================================
   -- procedure commented out by ronayp on 2024.06.02. : media_history, passing_history, passing_media_history tables are missing

  -- PROCEDURE archive_data;  
 
  -- ===============================================================================================================================================================

-- ===============================================================================================================================================================
   -- procedure commented out by ronayp on 2024.06.02. : tmp_kkep_report_portal table missing

--   PROCEDURE forgfer_report(p_date IN DATE, p_directory IN VARCHAR);
  
  -- ===============================================================================================================================================================


	procedure purge_recycle_bin;  
 
  -- ===============================================================================================================================================================

end kafir_util;

create or replace package body "KAFIR_UTIL" is

  -- ===============================================================================================================================================================

	function convert_to_date (
		p_high_value in varchar2
	) return date is
		v_result date;
	begin
		execute immediate 'SELECT '
		                  || p_high_value
		                  || ' FROM dual'
		  into v_result;
		return v_result;
	end convert_to_date;

  -- ===============================================================================================================================================================

	procedure log_success (
		p_proc_name  in varchar2,
		p_debug_info in varchar2,
		p_message    in varchar2
	) is
	begin
		event_log(
		         p_package_name => c_package_name,
		         p_procedure_name => p_proc_name,
		         p_debug_info => p_debug_info,
		         p_event_type => 'LOG',
		         p_message => p_message
		);
	end log_success;

  -- ===============================================================================================================================================================

	procedure log_error (
		p_proc_name  in varchar2,
		p_debug_info in varchar2,
		p_message    in varchar2
	) is
	begin
		event_log(
		         p_package_name => c_package_name,
		         p_procedure_name => p_proc_name,
		         p_debug_info => p_debug_info,
		         p_event_type => 'ERR',
		         p_message => p_message
		);
	end log_error;

  -- ===============================================================================================================================================================

	procedure execute_sql (
		p_proc_name  in varchar2,
		p_table_name in varchar2,
		p_cmd        in varchar2
	) is
	begin
		execute immediate p_cmd;
		log_success(
		           p_proc_name,
		           p_table_name,
		           p_cmd
		);
	exception
		when others then
			log_error(
			         p_proc_name,
			         p_table_name,
			         p_cmd
			         || ' - '
			         || substr(
			                  sqlerrm,
			                  1,
			                  4000
			            )
			);
	end execute_sql;

  -- ===============================================================================================================================================================

	procedure gather_stat is

		c_proc_name constant varchar2(30) := 'GATHER_STAT';

		procedure gather_stat_table (
			p_proc_name  in varchar2,
			p_table_name in varchar2
		) is

			l_estimate_percent number := 10;
			l_degree           number := 4;
			l_block_sample     varchar2(10) := 'FALSE';
			l_method_opt       varchar2(2000) := dbms_stats.get_param('METHOD_OPT');
		begin
			begin
				select estimate_percent,
				       degree,
				       block_sample,
				       method_opt
				  into
					l_estimate_percent,
					l_degree,
					l_block_sample,
					l_method_opt
				  from database_stats_params
				 where owner = user
				   and table_name = p_table_name;

			exception
				when no_data_found then
					begin
						select estimate_percent,
						       degree,
						       block_sample,
						       method_opt
						  into
							l_estimate_percent,
							l_degree,
							l_block_sample,
							l_method_opt
						  from database_stats_params
						 where owner = user
						   and table_name = 'DEFAULT';

					exception
						when no_data_found then
							null;
					end;
			end;

			dbms_stats.gather_table_stats(
			                             ownname => user,
			                             tabname => p_table_name,
			                             estimate_percent => l_estimate_percent,
			                             degree => l_degree,
			                             block_sample =>
			                                           case l_block_sample
					                                             when 'TRUE' then
					                                                 true
					                                             else
					                                                 false
			                                           end,
			                             method_opt => nvl(
					                  l_method_opt,
					                  dbms_stats.get_param(
						                   'METHOD_OPT'
					                   )
				                  ),
			                             cascade => true,
			                             no_invalidate => true
			);

			log_success(
			           p_proc_name,
			           p_table_name,
			           'gathered stat for table'
			);
		exception
			when others then
				log_error(
				         p_proc_name,
				         p_table_name,
				         'gathered stat for table'
				         || ' - '
				         || substr(
				                  sqlerrm,
				                  1,
				                  4000
				            )
				);
		end;

		procedure gather_stat_partition (
			p_proc_name      in varchar2,
			p_table_name     in varchar2,
			p_partition_name in varchar2
		) is
		begin
			dbms_stats.gather_table_stats(
			                             ownname => user,
			                             tabname => p_table_name,
			                             partname => p_partition_name,
			                             granularity => 'PARTITION',
			                             estimate_percent => 10,
			                             degree => 4,
			                             cascade => true,
			                             no_invalidate => true
			);

			log_success(
			           p_proc_name,
			           p_table_name,
			           p_partition_name || ' - gathered stat for partition.'
			);
		exception
			when others then
				log_error(
				         p_proc_name,
				         p_table_name,
				         p_partition_name
				         || ' - gather stat for table'
				         || ' - '
				         || substr(
				                  sqlerrm,
				                  1,
				                  4000
				            )
				);
		end;

	begin
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start gather stat.'
		);
		for rec_locked in (
			select distinct s.table_name
			  from user_tab_statistics s
			 where s.stattype_locked is not null
		) loop
			dbms_stats.unlock_table_stats(
			                             ownname => user,
			                             tabname => rec_locked.table_name
			);
		end loop;

		for rec in (
			select a.table_name,
			       a.partition_name
			  from user_tab_partitions a
			 where a.partition_name != 'PINIT'
			   and a.table_name not like 'BIN$%'
			   and ( a.last_analyzed is null
			    or a.partition_name like '%'
			                             || to_char(
				sysdate - 1,
				'YYYYMMDD'
			)
			                             || '%'
			    or a.table_name in ( 'KKEP_SESSION' )
			    or a.partition_position = (
				select max(x.partition_position)
				  from user_tab_partitions x
				 where x.table_name = a.table_name
			) )
			 order by a.table_name,
			          a.partition_name
		) loop
			gather_stat_partition(
			                     c_proc_name,
			                     rec.table_name,
			                     rec.partition_name
			);
		end loop;

		for rec in (
			select table_name
			  from user_tables
			 where nvl(
				    last_analyzed,
				    sysdate - 2
			    ) < sysdate - 12 / 24
			   and tablespace_name is not null
			 order by num_rows asc
		) loop
			gather_stat_table(
			                 c_proc_name,
			                 rec.table_name
			);
		end loop;

		log_success(
		           c_proc_name,
		           'END',
		           'finish gather stat.'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         'ERROR',
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end gather_stat;

  -- ===============================================================================================================================================================

	procedure encrypt_data (
		p_table_name    in varchar2,
		p_encrypt_type  in varchar2,
		p_retention_day in number,
		p_set           in varchar2,
		p_where         in varchar2
	) is

		v_encrypt_date date;
		v_cmd          varchar2(600);
		v_plsql_block  varchar2(800);
		v_updated_rows number;
		c_proc_name    constant varchar2(30) := 'ENCRYPT_DATA';
	begin
		begin
			select e.last_encrypted_day + 1
			  into v_encrypt_date
			  from encrypt_admin e
			 where e.table_name = p_table_name
			   and e.encrypt_type = p_encrypt_type;

		exception
			when no_data_found then
				execute immediate 'SELECT nvl(trunc(MIN(created_at)),trunc(SYSDATE)-30) FROM ' || p_table_name
				  into v_encrypt_date;
				insert into encrypt_admin (
					table_name,
					encrypt_type,
					last_encrypted_day
				) values ( p_table_name,
				           p_encrypt_type,
				           v_encrypt_date );

		end;

		while v_encrypt_date <= trunc(sysdate - p_retention_day) loop
			if p_encrypt_type = 'FULL' then
				v_cmd := 'UPDATE '
				         || p_table_name
				         || ' PARTITION FOR(to_date('''
				         || to_char(
				                   v_encrypt_date,
				                   'yyyy-mm-dd'
				            )
				         || ''', ''yyyy-mm-dd'')) p '
				         || '   SET '
				         || p_set
				         || ' '
				         || ' WHERE '
				         || p_where
				         || ';';
			elsif p_encrypt_type = 'PARTIAL' then
				v_cmd := 'UPDATE '
				         || p_table_name
				         || ' PARTITION FOR(to_date('''
				         || to_char(
				                   v_encrypt_date,
				                   'yyyy-mm-dd'
				            )
				         || ''', ''yyyy-mm-dd'')) p '
				         || '       SET '
				         || p_set
				         || ' '
				         || '     WHERE '
				         || p_where
				         || ' '
				         || '           (SELECT nvl(plate_number, ''#'') '
				         || '              FROM presumption PARTITION FOR(to_date('''
				         || to_char(
				                   v_encrypt_date,
				                   'yyyy-mm-dd'
				            )
				         || ''', ''yyyy-mm-dd'')));';
			end if;

			v_plsql_block  := 'BEGIN '
			                 || v_cmd
			                 || ' :v_updated_rows := SQL%ROWCOUNT; END;';
			execute immediate v_plsql_block
				using out v_updated_rows;
			if v_updated_rows > 0 then
				log_success(
				           c_proc_name,
				           p_table_name,
				           v_updated_rows
				           || ' rows updated ('
				           || p_encrypt_type
				           || ') on '
				           || to_char(
				                     v_encrypt_date,
				                     'YYYY.MM.DD.'
				              )
				);
			end if;

			update encrypt_admin e
			   set
				e.last_encrypted_day = v_encrypt_date
			 where e.table_name = p_table_name
			   and e.encrypt_type = p_encrypt_type;

			commit;
			v_encrypt_date := v_encrypt_date + 1;
		end loop;

	end encrypt_data;

  -- ===============================================================================================================================================================

	procedure encrypt_plate_numbers is
		c_proc_name  constant varchar2(30) := 'ENCRYPT_PLATE_NUMBERS';
		v_table_name varchar2(30);
	begin
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start encrypt plate number'
		);
		encrypt_data(
		            'KKEP_EVENT_BUFFER',
		            'FULL',
		            30,
		            'p.PLATE = NULL',
		            'p.PLATE IS NOT NULL AND p.PROCESSED = 1'
		);
		encrypt_data(
		            'KKEP_EVENT_BUFFER',
		            'FULL',
		            30,
		            'p.PLATE_REAR = NULL',
		            'p.PLATE_REAR IS NOT NULL AND p.PROCESSED = 1'
		);
		encrypt_data(
		            'PRESUMPTION',
		            'FULL',
		            30,
		            'p.PLATE_NUMBER = NULL',
		            'p.PLATE_NUMBER IS NOT NULL'
		);
		encrypt_data(
		            'PASSING',
		            'FULL',
		            30,
		            'p.PLATE_NUMBER = ''x''',
		            'p.PLATE_NUMBER IS NOT NULL'
		);
		encrypt_data(
		            'PASSING',
		            'FULL',
		            30,
		            'p.PLATE_NUMBER_REAR = ''x''',
		            'p.PLATE_NUMBER_REAR IS NOT NULL'
		);
		encrypt_data(
		            'PASSING',
		            'PARTIAL',
		            30,
		            'p.PLATE_NUMBER = ''x''',
		            'p.PLATE_NUMBER IS NOT NULL AND p.PLATE_NUMBER NOT IN '
		);
		encrypt_data(
		            'PASSING',
		            'PARTIAL',
		            30,
		            'p.PLATE_NUMBER_REAR = ''x''',
		            'p.PLATE_NUMBER_REAR IS NOT NULL AND p.PLATE_NUMBER_REAR NOT IN '
		);
		encrypt_data(
		            'KBKR_DATA',
		            'FULL',
		            30,
		            'p.PLATE_NUMBER = NULL',
		            'p.PLATE_NUMBER IS NOT NULL'
		);
		encrypt_data(
		            'KBKR_DATA',
		            'PARTIAL',
		            30,
		            'p.PLATE_NUMBER = NULL',
		            'p.PLATE_NUMBER IS NOT NULL AND p.PLATE_NUMBER NOT IN '
		);

--      encrypt_data('KONYIR','FULL',30,'p.PLATE_NUMBER = NULL', 'p.PLATE_NUMBER IS NOT NULL');

		log_success(
		           c_proc_name,
		           'END',
		           'finish encrypt plate number'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         v_table_name,
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end encrypt_plate_numbers;

  -- ===============================================================================================================================================================

	procedure delete_table (
		p_table_name     in varchar2,
		p_retention_date in date,
		p_batchsize      in number
	) is

		c_proc_name  constant varchar2(30) := 'DELETE_TABLE';
		v_count      number;
		v_total      number;
		v_countquery varchar2(1024);
		v_deletesql  varchar2(1024);
	begin
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'delete old data from "'
		           || p_table_name
		           || '" started'
		);
		v_count := 1;
		v_total := 0;
		while ( v_count > 0 ) loop
			v_countquery := 'SELECT COUNT(1) FROM '
			                || p_table_name
			                || ' WHERE created_at < TO_DATE('''
			                || to_char(
			                          p_retention_date,
			                          'YYYY.MM.DD HH24:MI:SS'
			                   )
			                || ''',''YYYY.MM.DD HH24:MI:SS'') AND rownum <= '
			                || p_batchsize;

			execute immediate v_countquery
			  into v_count;
			if ( v_count > 0 ) then
				v_total     := v_total + v_count;
				v_deletesql := 'DELETE FROM '
				               || p_table_name
				               || ' WHERE created_at < TO_DATE('''
				               || to_char(
				                         p_retention_date,
				                         'YYYY.MM.DD HH24:MI:SS'
				                  )
				               || ''',''YYYY.MM.DD HH24:MI:SS'') AND rownum <= '
				               || p_batchsize;

				execute immediate v_deletesql;
				log_success(
				           c_proc_name,
				           'LOG',
				           v_deletesql
				);
				log_success(
				           c_proc_name,
				           'LOG',
				           v_total
				           || ' records have been deleted from '
				           || p_table_name
				);
				commit;
			end if;

		end loop;

		log_success(
		           c_proc_name,
		           'END',
		           'finished'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         p_table_name,
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end delete_table;

  -- ===============================================================================================================================================================

	procedure create_range_tab_parts is

		v_part_date  date;
		v_part_name  varchar2(30);
		v_table_name varchar2(30);
		v_cmd        varchar2(300);
		c_proc_name  constant varchar2(30) := 'CREATE_RANGE_TAB_PARTS';
	begin
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start maintain partitions'
		);
		for part_rec in (
			select x.table_name,
			       x.high_value
			  from (
				select p.table_name,
				       t.partition_name,
				       t.high_value,
				       t.partition_position,
				       max(t.partition_position)
				       over(partition by p.table_name) max_part_pos
				  from user_part_tables p,
				       user_tab_partitions t,
				       retention_manager_params m
				 where p.partitioning_type = 'RANGE'
				   and p.interval is null
				   and p.table_name = t.table_name (+)
				   and p.table_name = m.table_name
				   and t.partition_name (+) != 'PINIT'
			) x
			 where nvl(
				x.partition_position,
				- 1
			) = nvl(
				x.max_part_pos,
				- 1
			)
		) loop
			v_table_name := part_rec.table_name;
			if part_rec.high_value is not null then
				v_part_date := convert_to_date(part_rec.high_value) + 1;
			else
				v_part_date := trunc(sysdate);
			end if;

			while v_part_date <= trunc(sysdate) + 5 loop
				v_part_name := 'P'
				               || to_char(
				                         v_part_date - 1,
				                         'YYYYMMDD'
				                  );
				v_cmd       := 'ALTER TABLE '
				         || part_rec.table_name
				         || ' SPLIT PARTITION PINIT AT (to_date('''
				         || to_char(
				                   v_part_date,
				                   'YYYY.MM.DD HH24:MI:SS'
				            )
				         || ''',''YYYY.MM.DD HH24:MI:SS''))'
				         || 'INTO (PARTITION '
				         || v_part_name
				         || ', PARTITION PINIT) UPDATE GLOBAL INDEXES';

				v_part_date := v_part_date + 1;
				execute_sql(
				           c_proc_name,
				           part_rec.table_name,
				           v_cmd
				);
			end loop;

		end loop;

		log_success(
		           c_proc_name,
		           'END',
		           'finish maintain partitions'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         v_table_name,
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end create_range_tab_parts;

  -- ===============================================================================================================================================================

	procedure maintain_data (
		p_max_partitons_to_drop in number
	) is

		v_retention_date  date;
		v_high_value_date date;
		v_table_name      varchar2(30);
		v_partition_name  varchar2(30);
		v_cmd             varchar2(2000);
		v_refcur          sys_refcursor;
		v_record          user_tab_partitions%rowtype;
		c_proc_name       constant varchar2(30) := 'MAINTAIN_DATA';
		v_rowcounter      number;

		procedure maintain_partition (
			p_interval_type         in varchar2,
			p_partition_name        in varchar2,
			p_max_partitons_to_drop in number
		) is
			v_partitions_dropped number;
		begin
			v_partitions_dropped := 0;
			open v_refcur for 'SELECT * FROM user_tab_partitions WHERE partition_name != ''PINIT'' AND table_name = '''
			                  || v_table_name
			                  || '''';

			loop
				fetch v_refcur into v_record;
				exit when v_refcur%notfound;
				v_high_value_date := convert_to_date(v_record.high_value);
				if
					p_interval_type = 'D'
					and p_partition_name like 'SYS/_%' escape '/'
				then
					v_partition_name := 'P'
					                    || to_char(
					                              v_high_value_date - interval '1' day,
					                              'YYYYMMDD'
					                       );
					v_cmd            := 'ALTER TABLE '
					         || v_table_name
					         || ' RENAME PARTITION '
					         || p_partition_name
					         || ' TO '
					         || v_partition_name;

					execute_sql(
					           c_proc_name,
					           v_table_name,
					           v_cmd
					);
				else
					v_partition_name := v_record.partition_name;
				end if;

				if
					v_high_value_date < v_retention_date
					and v_partitions_dropped < p_max_partitons_to_drop
				then
					v_partitions_dropped := v_partitions_dropped + 1;
					v_cmd                := 'ALTER TABLE '
					         || v_table_name
					         || ' DROP PARTITION '
					         || v_partition_name
					         || ' UPDATE GLOBAL INDEXES';
					execute_sql(
					           c_proc_name,
					           v_table_name,
					           v_cmd
					);
				end if;

			end loop;

			close v_refcur;
		end;

	begin
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start maintain data'
		);
		for rec_param in (
			select m.table_name,
			       case
			           when p.interval is not null then
			               'INTERVAL'
			           else
			               nvl(
				               p.partitioning_type,
				               'NORMAL'
			               )
			       end as handling_type,
			       m.interval_type,
			       m.retention_value,
			       (
				       select count(1)
				         from user_constraints t
				         join user_constraints w
				       on ( t.constraint_name = w.r_constraint_name )
				         left join user_part_tables pt
				       on w.table_name = pt.table_name
				        where t.table_name = p.table_name
				          and t.table_name <> w.table_name
				          and nvl(
					       pt.partitioning_type,
					       'NULL'
				       ) <> 'REFERENCE'
			       ) as fk_constraints
			  from user_part_tables p,
			       retention_manager_params m
			 where m.table_name = p.table_name (+)
			   and m.status = 'ACTIVE'
			   and m.retention_value > 0
			 order by m.maintain_order asc
		) loop
			v_table_name := rec_param.table_name;
			v_cmd        := null;
			case
				when rec_param.interval_type = 'D' then
					v_retention_date := trunc(sysdate) - numtodsinterval(
					                                                    rec_param.retention_value,
					                                                    'day'
					                                     );
				when rec_param.interval_type = 'M' then
					v_retention_date := trunc(
					                         sysdate,
					                         'MM'
					                    ) - numtoyminterval(
					                                       rec_param.retention_value,
					                                       'month'
					                        );
				when rec_param.interval_type = 'Y' then
					v_retention_date := trunc(
					                         sysdate,
					                         'YY'
					                    ) - numtoyminterval(
					                                       rec_param.retention_value,
					                                       'year'
					                        );
			end case;

			if rec_param.handling_type = 'NORMAL' then
				delete_table(
				            v_table_name,
				            v_retention_date,
				            10000
				);
			elsif rec_param.handling_type in ( 'INTERVAL',
			                                   'RANGE' ) then
				if rec_param.fk_constraints > 0 then
					delete_table(
					            v_table_name,
					            v_retention_date,
					            10000
					);
					maintain_partition(
					                  rec_param.interval_type,
					                  v_record.partition_name,
					                  p_max_partitons_to_drop
					);
				elsif rec_param.fk_constraints = 0 then
					maintain_partition(
					                  rec_param.interval_type,
					                  v_record.partition_name,
					                  p_max_partitons_to_drop
					);
				end if;
			end if;

		end loop;

		log_success(
		           c_proc_name,
		           'END',
		           'finish maintain data'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         v_table_name,
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end;

  -- ===============================================================================================================================================================

	procedure rename_partitions is

		v_high_value_date date;
		v_table_name      varchar2(30);
		v_partition_name  varchar2(30);
		v_cmd             varchar2(2000);
		v_refcur          sys_refcursor;
		v_record          user_tab_partitions%rowtype;
		c_proc_name       constant varchar2(30) := 'RENAME_PARTITIONS';

		procedure rename_partition (
			p_table_name in varchar2
		) is
		begin
			open v_refcur for 'SELECT * FROM user_tab_partitions WHERE partition_name != ''PINIT'' AND partition_name LIKE ''%SYS%'' AND table_name = '''
			                  || p_table_name
			                  || '''';

			loop
				fetch v_refcur into v_record;
				exit when v_refcur%notfound;
				v_high_value_date := convert_to_date(v_record.high_value);
				v_partition_name  := 'P'
				                    || to_char(
				                              v_high_value_date - interval '1' day,
				                              'YYYYMMDD'
				                       );
				v_cmd             := 'ALTER TABLE '
				         || p_table_name
				         || ' RENAME PARTITION '
				         || v_record.partition_name
				         || ' TO '
				         || v_partition_name;

				execute_sql(
				           c_proc_name,
				           p_table_name,
				           v_cmd
				);
			end loop;

			close v_refcur;
		end;

	begin
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start renaming partitions'
		);
		execute_sql(
		           c_proc_name,
		           'DDL_LOCK_TIMEOUT',
		           'ALTER SESSION SET DDL_LOCK_TIMEOUT = 60'
		);
		for rec_param in (
			select p.table_name,
			       case
			           when p.interval is not null then
			               'INTERVAL'
			           else
			               nvl(
				               p.partitioning_type,
				               'NORMAL'
			               )
			       end as handling_type
			  from user_part_tables p
		) loop
			if rec_param.handling_type in ( 'INTERVAL',
			                                'RANGE' ) then
				v_table_name := rec_param.table_name;
				rename_partition(v_table_name);
			end if;
		end loop;

		log_success(
		           c_proc_name,
		           'END',
		           'finish renaming partitions'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         v_table_name,
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end rename_partitions;

-- ===============================================================================================================================================================

	procedure restart_stopped_workflows is
		c_proc_name constant varchar2(30) := 'RESTART_WORKFLOWS';
		v_cnt       number := 0;
	begin
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'begin restarting stopped workflows'
		);
		for i in (
			select hibernate_sequence.nextval id,
			       pr.id presumption_id,
			       wh.correlation_id correlation_id,
			       wh.device_id device_id,
			       wh.external_id external_id,
			       wh.kkep_event_buffer_id internal_id
			  from presumption pr
			  left join workflow_head wh
			on pr.id = wh.presumption_id
			 where pr.created_at > sysdate - 10
			   and pr.kafir_presumption_strength = 'STRONG'
			   and pr.sent_to_robocop is null
			   and 0 = (
				select count(*)
				  from presumption_media pm
				  join media m
				on m.id = pm.media_id
				 where pm.presumption_id = pr.id
				   and m.has_blob = 0
			)
			   and 0 < (
				select count(*)
				  from presumption_media pm
				  join media m
				on m.id = pm.media_id
				 where pm.presumption_id = pr.id
				   and m.has_blob = 1
			)
			   and 0 = (
				select count(*)
				  from internal_data id
				 where id.correlation_id = wh.correlation_id
				   and id.status in ( 'ASYNC_WAIT',
				                      'PREPARED' )
			)
			   and wh.result_step_id = 'REQUEST_MISSING_PRESUMPTION_MEDIAS'
			   and wh.result_status = 'SUSPENDED'
		) loop
			begin
				insert into internal_data (
					"ID",
					"MODIFIED_AT",
					"CORRELATION_ID",
					"DEVICE_ID",
					"EXTERNAL_ID",
					"PRIORITY",
					"STATUS",
					"STEP_ID",
					"TYPE",
					"DO_NOT_WAKE_ME_UP_UNTIL",
					"DO_NOT_WAKE_UP_WORKFLOW",
					"CREATED_AT",
					"FAIL_ON_STEP_NOT_FOUND",
					"INTERNAL_ID"
				) values ( i.id,
				           sysdate,
				           i.correlation_id,
				           i.device_id,
				           i.external_id,
				           'NORMAL',
				           'PREPARED',
				           'REQUEST_MISSING_PRESUMPTION_MEDIAS',
				           'RESUME_WORKFLOW',
				           sysdate,
				           0,
				           sysdate,
				           0,
				           i.internal_id );

				commit;
				log_success(
				           c_proc_name,
				           'INTERNAL_DATA',
				           'restarting stopped workflow. PRESUMPTION_ID: ' || i.presumption_id
				);
				v_cnt := v_cnt + 1;
			exception
				when others then
					log_error(
					         c_proc_name,
					         'INTERNAL_DATA',
					         substr(
					               sqlerrm,
					               1,
					               4000
					         )
					);
			end;
		end loop;

		log_success(
		           c_proc_name,
		           'END',
		           'finished restarting stopped workflows. Number of rows inserted: ' || v_cnt
		);
	end restart_stopped_workflows;

-- ===============================================================================================================================================================

	procedure start_maintain is
	begin
		create_range_tab_parts();
    -- archive_data(); procedure commented out by ronayp on 2024.06.02. : ksh_kkep_report_portal table missing
		rename_partitions();
		maintain_data(2);
		restart_stopped_workflows();
		encrypt_plate_numbers();
		maintain_database_tables();
		gather_stat();
		purge_recycle_bin();
	end start_maintain;

	procedure fill_kkep_report_portal (
		p_days   in number,
		p_offset in number
	) is

		c_proc_name constant varchar2(30) := 'FILL_KKEP_REPORT_PORTAL';
		c_kkep_type constant varchar2(3) := 'FIX';
		v_date_from date;
		v_date_to   date;
	begin
		v_date_to   := trunc(sysdate) - p_offset;
		v_date_from := v_date_to - p_days;
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start fill_kkep_report_portal stored procedure ['
		           || v_date_from
		           || '] to ['
		           || v_date_to
		           || ']'
		);

        -- insert into ksh_kkep_report_portal
		insert into ksh_kkep_report_portal (
			kkepreport_id,
			created_at,
			started_at,
			lane,
			device_id,
			address,
			portal_id
		)
			select re.id,
			       re.created_at,
			       re.start_at,
			       sp.lane,
			       re.device_id,
			       sp.address,
			       p.portal_id
			  from kkep_report re
			  left join spot sp
			on ( re.spot_id = sp.id )
			  left join kkep_device d
			on ( re.device_id = d.device_id )
			  left join kkep_portal p
			on p.id = d.kkep_portal_id
			 where re.created_at between v_date_from and v_date_to
			   and d.device_type = c_kkep_type;

		log_success(
		           c_proc_name,
		           'END',
		           'finish fill_kkep_report_portal stored procedure'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         'ERROR',
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end fill_kkep_report_portal;

	procedure ksh_report (
		p_days      in number,
		p_offset    in number,
		p_directory in varchar,
		p_portals   in varchar2
	) is

		c_proc_name             constant varchar2(30) := 'KSH_REPORT';
		c_open_to_write         constant varchar2(1) := 'w';
		c_open_to_append        constant varchar2(1) := 'a';
		c_date_format           constant varchar2(21) := 'YYYY.MM.DD HH24:MI:SS';
		v_report_date_from      date;
		v_report_date_to        date;
		v_report_file_size      number;
		v_report_file_blocksize number;
		v_report_file_name      varchar(100);
		v_report_file_exist     boolean;
		v_report_file           utl_file.file_type;
		cursor v_portal_list is
		select *
		  from (
			with data as (
				select p_portals str
				  from dual
			)
			select trim(regexp_substr(
				str,
				'[^,]+',
				1,
				level
			)) str
			  from data
			connect by
				instr(
					str,
					',',
					1,
					level - 1
				) > 0
		);

	begin
		v_report_date_to   := trunc(sysdate) - p_offset;
		v_report_date_from := v_report_date_to - p_days;
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start KSH report from ['
		           || v_report_date_from
		           || '] to ['
		           || v_report_date_to
		           || ']'
		);

		for portal in v_portal_list loop
			begin
				log_success(
				           c_proc_name,
				           'LOOP',
				           'start KSH report - ' || portal.str
				);
				v_report_file_name := 'ORFK_'
				                      || portal.str
				                      || '_'
				                      || to_char(
				                                v_report_date_from,
				                                'YYMM'
				                         )
				                      || '.csv';

				utl_file.fgetattr(
				                 p_directory,
				                 v_report_file_name,
				                 v_report_file_exist,
				                 v_report_file_size,
				                 v_report_file_blocksize
				);
				if v_report_file_exist then
					v_report_file := utl_file.fopen(
					                               p_directory,
					                               v_report_file_name,
					                               c_open_to_append
					                 );
				else
					v_report_file := utl_file.fopen(
					                               p_directory,
					                               v_report_file_name,
					                               c_open_to_write
					                 );
					utl_file.put(
					            v_report_file,
					            'helyszin;ido;sav;jarmu honossaga;jarmu tipusa'
					);
					utl_file.new_line(v_report_file);
				end if;

				for rec in (
					select t.portal_id,
					       to_char(
						       p.at_timestamp,
						       c_date_format
					       ) as at_time,
					       t.lane,
					       p.country_code,
					       case
					           when length(
						           kd.robocop_vehicle_category
					           ) = 2 then
					               kd.robocop_vehicle_category
					           when kd.robocop_vehicle_category is null
					               or length(
						           kd.robocop_vehicle_category
					           ) <> 2 then
					               p.robocop_vehicle_category
					       end as robocop_vehicle_category
					  from passing p
					  left join kbkr_data kd
					on p.id = kd.passing_id
					   and kd.plate_type = 'FRONT'
					  left join ksh_kkep_report_portal t
					on ( p.kkepreport_id = t.kkepreport_id )
					 where p.created_at between v_report_date_from and v_report_date_to + 1
					   and p.at_timestamp between v_report_date_from and v_report_date_to
					   and t.portal_id = portal.str
					 order by p.at_timestamp asc
				) loop
					utl_file.put(
					            v_report_file,
					            rec.portal_id
					            || ';'
					            || rec.at_time
					            || ';'
					            || rec.lane
					            || ';'
					            || rec.country_code
					            || ';'
					            || rec.robocop_vehicle_category
					);

					utl_file.new_line(v_report_file);
				end loop;

				utl_file.fclose(v_report_file);
			exception
				when others then
					log_error(
					         c_proc_name,
					         'ERROR',
					         substr(
					               sqlerrm,
					               1,
					               4000
					         )
					);
			end;
		end loop;

		log_success(
		           c_proc_name,
		           'END',
		           'finish KSH report'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         'ERROR',
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end ksh_report;
-- =============================================================================================================================================================

	procedure vh_measures_report (
		p_month_offset in number,
		p_directory    in varchar
	) is

		c_proc_name             constant varchar2(30) := 'VH_MEASURES_REPORT';
		c_open_to_write         constant varchar2(1) := 'w';
		c_date_format           constant varchar2(30) := 'YYYY-MM-DD"T"HH24:MI:SS';
		v_report_begin          date;
		v_report_end            date;
		v_report_file_size      number;
		v_report_file_blocksize number;
		v_report_file_name      varchar2(100);
		v_report_file_exist     boolean;
		v_report_file           utl_file.file_type;

        -- UTF-8 BOM
		v_utf8_bom              raw(3) := utl_raw.cast_to_raw(chr(239)
		                                         || chr(187)
		                                         || chr(191));
		v_utf8_header           varchar2(32767);
		v_utf8_line             varchar2(32767);
	begin
		v_report_begin     := trunc(
		                       add_months(
		                                 sysdate,
		                                 p_month_offset
		                       ),
		                       'MM'
		                  );
		v_report_end       := last_day(v_report_begin) + interval '1' day;

        -- Set NLS parameters for the session
		execute immediate 'ALTER SESSION SET NLS_NUMERIC_CHARACTERS = ''. ''';
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start VH_MEASURES report for ['
		           || v_report_begin
		           || ']'
		);
		v_report_file_name := 'VH_MEASUREMENTS_'
		                      || to_char(
		                                v_report_begin,
		                                'YYMM'
		                         )
		                      || '.csv';
		v_report_file      := utl_file.fopen(
		                               p_directory,
		                               v_report_file_name,
		                               c_open_to_write
		                 );

        -- Write the BOM to the file
		utl_file.put_raw(
		                v_report_file,
		                v_utf8_bom
		);

        -- Write header in UTF-8 encoding
		v_utf8_header      := 'vármegye;eszköz;mérés kezdete;mérés vége;hely;cím;kezelő;üzemóra;elhaladások száma;vélelmek száma;korlátozás típusa;mérés módja;szgk. megengedett sebesség;szgk. dokumentálási seb.;tgk. megengedett sebesség;tgk. dokumentálási seb.'
		;
		utl_file.put_line(
		                 v_report_file,
		                 v_utf8_header
		);
		for rec in (
			select "vármegye",
			       "eszköz",
			       to_char(
				       "mérés kezdete",
				       c_date_format
			       ) as "mérés kezdete",
			       to_char(
				       "mérés vége",
				       c_date_format
			       ) as "mérés vége",
			       "hely kódja",
			       "cím",
			       "kezelő",
			       "üzemóra",
			       "elhaladások száma",
			       "vélelmek száma",
			       "korlátozás típusa",
			       "mérés módja",
			       "szgk. megengedett sebesség",
			       "szgk. dokumentálási seb.",
			       "tgk. megengedett sebesség",
			       "tgk. dokumentálási seb."
			  from vh_measures_view
			 where "mérés vége" is null
			    or "mérés vége" between v_report_begin and v_report_end
			 order by "mérés kezdete" asc
		) loop
			v_utf8_line := rec."vármegye"
			               || ';'
			               || rec."eszköz"
			               || ';'
			               || rec."mérés kezdete"
			               || ';'
			               || rec."mérés vége"
			               || ';'
			               || rec."hely kódja"
			               || ';'
			               || rec."cím"
			               || ';'
			               || rec."kezelő"
			               || ';'
			               || rec."üzemóra"
			               || ';'
			               || rec."elhaladások száma"
			               || ';'
			               || rec."vélelmek száma"
			               || ';'
			               || rec."korlátozás típusa"
			               || ';'
			               || rec."mérés módja"
			               || ';'
			               || rec."szgk. megengedett sebesség"
			               || ';'
			               || rec."szgk. dokumentálási seb."
			               || ';'
			               || rec."tgk. megengedett sebesség"
			               || ';'
			               || rec."tgk. dokumentálási seb.";

            -- Write each line in UTF-8 encoding
			utl_file.put_line(
			                 v_report_file,
			                 v_utf8_line
			);
		end loop;

		utl_file.fclose(v_report_file);
		log_success(
		           c_proc_name,
		           'END',
		           'finish VH_MEASURES report'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         'ERROR',
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end vh_measures_report;

-- =============================================================================================================================================================
	procedure vh_measures_aggregated_report (
		p_month_offset in number,
		p_directory    in varchar
	) is
		c_proc_name             constant varchar2(30) := 'VH_MEASURES_AGGREGATED_REPORT';
		c_open_to_write         constant varchar2(1) := 'w';
		c_date_format           constant varchar2(30) := 'YYYY-MM-DD"T"HH24:MI:SS';
		v_report_begin          date;
		v_report_end            date;
		v_report_file_size      number;
		v_report_file_blocksize number;
		v_report_file_name      varchar2(100);
		v_report_file_exist     boolean;
		v_report_file           utl_file.file_type;

        -- UTF-8 BOM
		v_utf8_bom              raw(3) := utl_raw.cast_to_raw(chr(239)
		                                         || chr(187)
		                                         || chr(191));
		v_utf8_header           varchar2(32767);
		v_utf8_line             varchar2(32767);
	begin
		v_report_begin     := trunc(
		                       add_months(
		                                 sysdate,
		                                 p_month_offset
		                       ),
		                       'MM'
		                  );
		v_report_end       := last_day(v_report_begin) + interval '1' day;

        -- Set NLS parameters for the session
		execute immediate 'ALTER SESSION SET NLS_NUMERIC_CHARACTERS = ''. ''';
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start VH_MEASURES_AGGREGATED report for ['
		           || v_report_begin
		           || ']'
		);
		v_report_file_name := 'VH_MEASUREMENTS_AGGREGATED_'
		                      || to_char(
		                                v_report_begin,
		                                'YYMM'
		                         )
		                      || '.csv';
		v_report_file      := utl_file.fopen(
		                               p_directory,
		                               v_report_file_name,
		                               c_open_to_write
		                 );

        -- Write the BOM to the file
		utl_file.put_raw(
		                v_report_file,
		                v_utf8_bom
		);

        -- Write header in UTF-8 encoding
		v_utf8_header      := 'vármegye;hely;cím;mérések száma;elhaladások száma;vélelmek száma;összes üzemóra;elhaladás nélk. üzemórák;elhalad. nélk. órák aránya'
		;
		utl_file.put_line(
		                 v_report_file,
		                 v_utf8_header
		);
		for rec in (
			with measures_aggregated as (
				select count(1) "mérések száma",
				       sum("elhaladások száma") "elhaladások száma",
				       sum("vélelmek száma") "vélelmek száma",
				       sum("üzemóra") "összes üzemóra",
				       (
					       select sum("üzemóra")
					         from vh_measures_view vmv
					        where vmv."hely kódja" = vm."hely kódja"
					          and vmv."elhaladások száma" = 0
				       ) "elhaladás nélk. üzemórák",
				       vm."hely kódja"
				  from vh_measures_view vm
				 where "mérés vége" is null
				    or "mérés vége" between v_report_begin and v_report_end
				 group by vm."hely kódja"
			)
			select (
				select vmv2."vármegye"
				  from vh_measures_view vmv2
				 where vmv2."hely kódja" = ma."hely kódja"
				   and rownum = 1
			) as "vármegye",
			       "hely kódja",
			       (
				       select vmv3."cím"
				         from vh_measures_view vmv3
				        where vmv3."hely kódja" = ma."hely kódja"
				          and rownum = 1
			       ) as "cím",
			       ma."mérések száma",
			       ma."elhaladások száma",
			       ma."vélelmek száma",
			       ma."összes üzemóra",
			       ma."elhaladás nélk. üzemórák",
			       ma."elhaladás nélk. üzemórák" / nvl(
				       nullif(
					       ma."összes üzemóra",
					       0
				       ),
				       nvl(
					       nullif(
						       ma."elhaladás nélk. üzemórák",
						       0
					       ),
					       1
				       )
			       ) as "elhalad. nélk. órák aránya"
			  from measures_aggregated ma
		) loop
			v_utf8_line := rec."vármegye"
			               || ';'
			               || rec."hely kódja"
			               || ';'
			               || rec."cím"
			               || ';'
			               || rec."mérések száma"
			               || ';'
			               || rec."elhaladások száma"
			               || ';'
			               || rec."vélelmek száma"
			               || ';'
			               || rec."összes üzemóra"
			               || ';'
			               || rec."elhaladás nélk. üzemórák"
			               || ';'
			               || rec."elhalad. nélk. órák aránya";

            -- Write each line in UTF-8 encoding
			utl_file.put_line(
			                 v_report_file,
			                 v_utf8_line
			);
		end loop;

		utl_file.fclose(v_report_file);
		log_success(
		           c_proc_name,
		           'END',
		           'finish VH_MEASURES report'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         'ERROR',
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end vh_measures_aggregated_report;

-- =============================================================================================================================================================
	function get_csv_month_header (
		p_input_date date
	) return varchar2 is
		v_days_in_month number;
		v_csv_header    varchar2(4000);
	begin
        -- Determine the number of days in the input date's month
		v_days_in_month := to_number ( to_char(
			last_day(p_input_date),
			'DD'
		) );

        -- Initialize the CSV header string
		v_csv_header    := '';

        -- Loop through each day of the month and construct the CSV header string
		for i in 1..v_days_in_month loop
			if i = 1 then
				v_csv_header := to_char(
				                       i,
				                       'FM00'
				                );
			else
				v_csv_header := v_csv_header
				                || ';'
				                || to_char(
				                          i,
				                          'FM00'
				                   );
			end if;
		end loop;

        -- Return the result
		return v_csv_header;
	end get_csv_month_header;

-- =============================================================================================================================================================
	procedure vh_upload_summary_report (
		p_month_offset in number,
		p_directory    in varchar
	) as
		c_proc_name             constant varchar2(30) := 'VH_UPLOAD_SUMMARY_REPORT';
		c_open_to_write         constant varchar2(1) := 'w';
		c_date_format           constant varchar2(30) := 'YYYY-MM-DD"T"HH24:MI:SS';
		v_report_begin          date;
		v_report_end            date;
		v_report_file_size      number;
		v_report_file_blocksize number;
		v_report_file_name      varchar2(100);
		v_report_file_exist     boolean;
		v_report_file           utl_file.file_type;

        -- UTF-8 BOM
		v_utf8_bom              raw(3) := utl_raw.cast_to_raw(chr(239)
		                                         || chr(187)
		                                         || chr(191));
		v_utf8_header           varchar2(32767);
		v_utf8_line             varchar2(32767);
		v_days_in_month         number;
		v_prefix                char;
		v_column_name           varchar2(8);
		v_column_value          varchar2(32767);
		v_cursor                integer;
		v_rec_tab               dbms_sql.desc_tab;
		v_col_cnt               integer;
		v_varchar2_value        varchar2(32767);
		v_status                integer;
		type t_column_map is
			table of pls_integer index by varchar2(30);
		v_column_map            t_column_map;
	begin
		v_report_begin     := trunc(
		                       add_months(
		                                 sysdate,
		                                 p_month_offset
		                       ),
		                       'MM'
		                  );
		v_report_end       := last_day(v_report_begin) + interval '1' day;
		v_days_in_month    := to_number ( to_char(
			last_day(v_report_begin),
			'DD'
		) );

        -- Set NLS parameters for the session
		execute immediate 'ALTER SESSION SET NLS_NUMERIC_CHARACTERS = ''. ''';
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'start '
		           || c_proc_name
		           || ' report for ['
		           || v_report_begin
		           || ']'
		);

		v_report_file_name := 'VH_UPLOAD_SUMMARY_'
		                      || to_char(
		                                v_report_begin,
		                                'YYMM'
		                         )
		                      || '.csv';
		v_report_file      := utl_file.fopen(
		                               p_directory,
		                               v_report_file_name,
		                               c_open_to_write
		                 );

        -- Write the BOM to the file
		utl_file.put_raw(
		                v_report_file,
		                v_utf8_bom
		);

        -- Write header in UTF-8 encoding
		v_utf8_header      := 'vármegye;eszköz;' || get_csv_month_header(v_report_begin);
		utl_file.put_line(
		                 v_report_file,
		                 v_utf8_header
		);
        
        -- Open a cursor to fetch the data
		v_cursor           := dbms_sql.open_cursor;
		dbms_sql.parse(
		              v_cursor,
		              'SELECT * FROM vh_upload_summary_view',
		              dbms_sql.native
		);
		dbms_sql.describe_columns(
		                         v_cursor,
		                         v_col_cnt,
		                         v_rec_tab
		);
		dbms_sql.define_column(
		                      v_cursor,
		                      1,
		                      v_varchar2_value,
		                      32767
		); -- Define first column
		dbms_sql.define_column(
		                      v_cursor,
		                      2,
		                      v_varchar2_value,
		                      32767
		); -- Define second column
       
        -- Populate the column map for quick lookup
		for i in 3..v_col_cnt loop
			dbms_sql.define_column(
			                      v_cursor,
			                      i,
			                      v_varchar2_value,
			                      32767
			);
			v_column_map(v_rec_tab(i).col_name) := i;
		end loop;

        -- Execute the cursor
		v_status           := dbms_sql.execute(v_cursor);
		v_prefix           :=
			case
				when p_month_offset = 0 then
					'N'
				else 'E'
			end;
		loop
			if dbms_sql.fetch_rows(v_cursor) > 0 then
				v_utf8_line := '';
				dbms_sql.column_value(
				                     v_cursor,
				                     1,
				                     v_varchar2_value
				);
				v_utf8_line := v_utf8_line
				               || v_varchar2_value
				               || ';';
				dbms_sql.column_value(
				                     v_cursor,
				                     2,
				                     v_varchar2_value
				);
				v_utf8_line := v_utf8_line
				               || v_varchar2_value
				               || ';';
				for i in 1..v_days_in_month loop
					v_column_name := v_prefix || to_char(
					                                    i,
					                                    'FM00'
					                             );
					if v_column_map.exists(v_column_name) then
						dbms_sql.column_value(
						                     v_cursor,
						                     v_column_map(v_column_name),
						                     v_varchar2_value
						);
						v_utf8_line := v_utf8_line
						               || nvl(
						                     v_varchar2_value,
						                     '0'
						                  )
						               || ';';
					else
						v_utf8_line := v_utf8_line || '0;';
					end if;
				end loop;

                -- Write each line in UTF-8 encoding
				utl_file.put_line(
				                 v_report_file,
				                 v_utf8_line
				);
			else
				exit;
			end if;
		end loop;

		dbms_sql.close_cursor(v_cursor);
		utl_file.fclose(v_report_file);
		log_success(
		           c_proc_name,
		           'END',
		           'finish '
		           || c_proc_name
		           || ' report'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         'ERROR',
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
			if utl_file.is_open(v_report_file) then
				utl_file.fclose(v_report_file);
			end if;
			if dbms_sql.is_open(v_cursor) then
				dbms_sql.close_cursor(v_cursor);
			end if;
	end vh_upload_summary_report;
-- =============================================================================================================================================================
	procedure maintain_database_tables as
		v_cmd       varchar2(255);
		c_proc_name constant varchar2(30) := 'MAINTAIN_DATABASE_TABLES';
	begin
		log_success(
		           c_proc_name,
		           'START',
		           'start maintain database'
		);
		v_cmd := 'ALTER SESSION SET DDL_LOCK_TIMEOUT = 60';
		execute_sql(
		           c_proc_name,
		           'DDL_LOCK_TIMEOUT',
		           v_cmd
		);
		for rec in (
			select m.maintain_order,
			       m.table_name
			  from database_maintenance_params m,
			       user_tables u
			 where u.table_name = m.table_name
			   and m.status = 'ACTIVE'
			   and ( m.last_maintained_at is null
			    or m.last_maintained_at + m.interval_in_days < sysdate )
			 order by maintain_order asc
		) loop
			maintain_table(rec.table_name);
		end loop;

		log_success(
		           c_proc_name,
		           'END',
		           'finish maintain database'
		);
	end maintain_database_tables;
-- ===============================================================================================================================================================

	procedure maintain_table (
		p_table_name in varchar2
	) as

		v_cmd                    varchar2(255);
		v_row_movement           varchar2(12 char);
		v_shrink_table           varchar2(3 char);
		v_rebuild_table_indicies varchar2(3 char);
		c_proc_name              constant varchar2(30) := 'MAINTAIN_TABLE';
	begin
		log_success(
		           c_proc_name,
		           'START',
		           'start maintain table ' || p_table_name
		);

      ------------------------------------------------------------------------------------------------
      --- ENABLE ROW MOVEMENT ---
      ------------------------------------------------------------------------------------------------
		select row_movement
		  into v_row_movement
		  from user_tables
		 where table_name = p_table_name;

		if ( v_row_movement = 'DISABLED' ) then
			modify_row_movement(
			                   p_table_name,
			                   'ENABLE'
			);
		end if;

      ------------------------------------------------------------------------------------------------
      --- SHRINK TABLE ---
      ------------------------------------------------------------------------------------------------
		select m.shrink_table
		  into v_shrink_table
		  from database_maintenance_params m,
		       user_tables u
		 where u.table_name = m.table_name
		   and m.table_name = p_table_name;

		if ( v_shrink_table = 'YES' ) then
			shrink_table(p_table_name);
		end if;

      ------------------------------------------------------------------------------------------------
      --- SHRINK PARTITIONS ---
      ------------------------------------------------------------------------------------------------
		for rec in (
			select *
			  from (
				select m.table_name,
				       p.partition_name,
				       m.max_partitions_to_srhink
				  from database_maintenance_params m,
				       user_tab_partitions p
				 where p.table_name = m.table_name
				   and m.table_name = p_table_name
				   and m.max_partitions_to_srhink > 0
				   and p.partition_name <> 'PINIT'
				 order by p.partition_position desc
			)
			 where rownum <= max_partitions_to_srhink
		) loop
			shrink_partition(
			                p_table_name,
			                rec.partition_name
			);
		end loop;

      ------------------------------------------------------------------------------------------------
      --- DISABLE ROW MOVEMENT ---
      ------------------------------------------------------------------------------------------------
		if ( v_row_movement = 'DISABLED' ) then
			modify_row_movement(
			                   p_table_name,
			                   'DISABLE'
			);
		end if;

      ------------------------------------------------------------------------------------------------
      --- REBUILD TABLE INDICIES ---
      ------------------------------------------------------------------------------------------------

		select m.rebuild_table_indicies
		  into v_rebuild_table_indicies
		  from database_maintenance_params m
		 where m.table_name = p_table_name;

		if ( v_rebuild_table_indicies = 'YES' ) then
			rebuild_table_indicies(p_table_name);
		end if;

      ------------------------------------------------------------------------------------------------
      -- REBUILD PARTITION INDICIES ---
      ------------------------------------------------------------------------------------------------

		for rec in (
			select m.maintain_order,
			       m.table_name,
			       p.partition_name
			  from database_maintenance_params m,
			       user_tab_partitions p
			 where m.table_name = p.table_name
			   and m.rebuild_partition_indicies = 'YES'
			   and p.partition_name like 'P2%'
		) loop
			rebuild_partition_indicies(
			                          p_table_name,
			                          rec.partition_name
			);
		end loop;

      ------------------------------------------------------------------------------------------------
      -- UPDATE LAST_MAINTAIND_AT ---
      ------------------------------------------------------------------------------------------------
		update database_maintenance_params
		   set
			last_maintained_at = sysdate
		 where table_name = p_table_name;

		commit;
		log_success(
		           c_proc_name,
		           'END',
		           'fhinish maintain table ' || p_table_name
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         'ERROR',
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end maintain_table;

 -- ===============================================================================================================================================================

	procedure shrink_table (
		p_table_name in varchar2
	) as
		v_cmd       varchar2(255);
		c_proc_name constant varchar2(30) := 'SHRINK_TABLE';
	begin
		v_cmd := 'ALTER TABLE '
		         || p_table_name
		         || ' SHRINK SPACE COMPACT';
		execute_sql(
		           c_proc_name,
		           p_table_name,
		           v_cmd
		);
		v_cmd := 'ALTER TABLE '
		         || p_table_name
		         || ' SHRINK SPACE';
		execute_sql(
		           c_proc_name,
		           p_table_name,
		           v_cmd
		);
		v_cmd := 'ALTER TABLE '
		         || p_table_name
		         || ' DEALLOCATE UNUSED';
		execute_sql(
		           c_proc_name,
		           p_table_name,
		           v_cmd
		);
	end shrink_table;

-- ===============================================================================================================================================================

	procedure shrink_partition (
		p_table_name     in varchar2,
		p_partition_name in varchar2
	) as
		v_cmd       varchar2(255);
		c_proc_name constant varchar2(30) := 'SHRINK_PARTITION';
	begin
		v_cmd := 'ALTER TABLE '
		         || p_table_name
		         || ' MODIFY PARTITION '
		         || p_partition_name
		         || ' SHRINK SPACE';
		execute_sql(
		           c_proc_name,
		           p_table_name
		           || '.'
		           || p_partition_name,
		           v_cmd
		);
		v_cmd := 'ALTER TABLE '
		         || p_table_name
		         || ' MODIFY PARTITION '
		         || p_partition_name
		         || ' DEALLOCATE UNUSED';
		execute_sql(
		           c_proc_name,
		           p_table_name
		           || '.'
		           || p_partition_name,
		           v_cmd
		);
	end shrink_partition;

-- ===============================================================================================================================================================

	procedure rebuild_table_indicies (
		p_table_name in varchar2
	) as
		v_cmd       varchar2(255);
		c_proc_name constant varchar2(30) := 'REBUILD_TABLE_INDICIES';
	begin
		for rec in (
			select i.index_name
			  from user_indexes i
			 where i.table_name = p_table_name
			   and i.index_name not like 'SYS%'
			   and i.partitioned = 'NO'
		) loop
			v_cmd := 'ALTER INDEX '
			         || rec.index_name
			         || ' REBUILD ONLINE';
			execute_sql(
			           c_proc_name,
			           p_table_name,
			           v_cmd
			);
		end loop;
	end rebuild_table_indicies;

-- ===============================================================================================================================================================

	procedure rebuild_partition_indicies (
		p_table_name     in varchar2,
		p_partition_name in varchar2
	) as
		v_cmd       varchar2(255);
		c_proc_name constant varchar2(30) := 'REBUILD_PARTITION_INDICIES';
	begin
		for rec in (
			select i.index_name,
			       p.partition_name
			  from user_indexes i,
			       user_tab_partitions p
			 where i.table_name = p.table_name
			   and i.table_name = p_table_name
			   and p.partition_name = p_partition_name
			   and i.index_name not like 'SYS%'
			   and i.partitioned = 'YES'
			 order by p.partition_position desc
		) loop
			v_cmd := 'ALTER INDEX '
			         || rec.index_name
			         || ' REBUILD PARTITION '
			         || rec.partition_name;
			execute_sql(
			           c_proc_name,
			           p_table_name
			           || '.'
			           || p_partition_name,
			           v_cmd
			);
		end loop;
	end rebuild_partition_indicies;


-- ===============================================================================================================================================================

	procedure modify_row_movement (
		p_table_name   in varchar2,
		p_row_movement in varchar2
	) as
		v_cmd       varchar2(255);
		c_proc_name constant varchar2(30) := 'MODIFY_ROW_MOVEMENT';
	begin
		if ( p_row_movement = 'DISABLE' ) then
			v_cmd := 'ALTER TABLE '
			         || p_table_name
			         || ' DISABLE ROW MOVEMENT';
			execute_sql(
			           c_proc_name,
			           p_table_name,
			           v_cmd
			);
		end if;

		for rec in (
			select w.table_name
			  from user_constraints t
			  join user_constraints w
			on ( t.constraint_name = w.r_constraint_name )
			  join user_part_tables q
			on ( q.table_name = w.table_name
			   and q.ref_ptn_constraint_name = w.constraint_name )
			 where t.table_name = p_table_name
		) loop
			v_cmd := 'ALTER TABLE '
			         || rec.table_name
			         || ' '
			         || p_row_movement
			         || ' ROW MOVEMENT';

			execute_sql(
			           c_proc_name,
			           rec.table_name,
			           v_cmd
			);
		end loop;

		if ( p_row_movement = 'ENABLE' ) then
			v_cmd := 'ALTER TABLE '
			         || p_table_name
			         || ' ENABLE ROW MOVEMENT';
			execute_sql(
			           c_proc_name,
			           p_table_name,
			           v_cmd
			);
		end if;

	end modify_row_movement;

-- ===============================================================================================================================================================
-- procedure commented out by ronayp on 2024.06.02. : media_history, passing_history, passing_media_history tables are missing
/*
  PROCEDURE archive_data IS
    c_proc_name               CONSTANT VARCHAR2(30) := 'ARCHIVE_DATA';
    v_archiver_keep_days      NUMBER;
    v_time_limit_in_minutes   NUMBER;
    v_archived_medias         NUMBER;
    v_archived_passings       NUMBER;
    v_archived_presumptions   NUMBER;
    v_count                   NUMBER;
    v_exec_time               NUMBER;
    v_archive_days            NUMBER;
    v_archiver_enabled        VARCHAR(16);
  BEGIN
      v_archived_medias:=0;
      v_archived_passings:=0;
      v_archived_presumptions:=0;
      v_archive_days:=30;
      v_exec_time:=dbms_utility.get_time;

      select nvl(to_number(parameter_value), 60) into v_archiver_keep_days from system_parameter where parameter_key = 'PASSIVE_DATA_HANDLER_KEEP_DAYS';
      select nvl(to_number(parameter_value), 60) into v_time_limit_in_minutes from system_parameter where parameter_key = 'PASSIVE_DATA_HANDLER_LIMIT_IN_MINUTES';
      select nvl(parameter_value, 'true') into v_archiver_enabled from system_parameter where parameter_key = 'PASSIVE_DATA_HANDLER_ENABLED';

      log_success(c_proc_name, 'START', 'ARCHIVE_DATA - stored procedure has been started');
      log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - parameter: v_archiver_enabled = '|| v_archiver_enabled);
      log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - parameter: v_archive_days = '|| v_archive_days);
      log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - parameter: v_archiver_keep_days = '|| v_archiver_keep_days);
      log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - parameter: v_time_limit_in_minutes = '|| v_time_limit_in_minutes);

      if v_archiver_enabled = 'true' then

          select count(1) into v_count  
              from passing p left join presumption p2 on p.id = p2.passing_id
              where p.created_at < trunc(sysdate) - v_archiver_keep_days 
              and p.created_at < ( select min(trunc(created_at)) + v_archive_days from passing);
          log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - parameter: v_count  = '|| v_count);

          for rec in (select p.id as passing_id, p2.id as presumption_id, p.created_at 
              from passing p left join presumption p2 on p.id = p2.passing_id
              where p.created_at < trunc(sysdate) - v_archiver_keep_days 
              and p.created_at < ( select min(trunc(created_at)) + v_archive_days from passing)
              order by p.created_at asc) 
          loop 
            begin

             if (dbms_utility.get_time - v_exec_time) / 6000 >= v_time_limit_in_minutes then
                log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - maximum execution time ('|| v_time_limit_in_minutes ||' minutes) exceeded.');
                exit;
             end if;

             insert into media_history (select m.* from passing_media pm join media m on m.id = pm.media_id where pm.passing_id = rec.passing_id);
             insert into passing_history select * from passing where id = rec.passing_id;
             insert into passing_media_history select * from passing_media pm where pm.passing_id = rec.passing_id;

             delete from media where id in (select pm.media_id from passing_media pm where pm.passing_id = rec.passing_id);
             v_archived_medias:=v_archived_medias + SQL%ROWCOUNT;

             delete from passing where id = rec.passing_id;

             v_archived_passings:=v_archived_passings + SQL%ROWCOUNT;

             if rec.presumption_id is not null then
                insert into presumption_history select * from presumption where id = rec.presumption_id;
                insert into presumption_media_history select * from presumption_media pm where pm.presumption_id = rec.presumption_id;
                delete from presumption where id = rec.presumption_id;
                v_archived_presumptions:=v_archived_presumptions + SQL%ROWCOUNT;
             end if;

             commit;

             exception 
                when others then
                log_error(c_proc_name, 'ERROR', 'ARCHIVE_DATA - unable to archive record with passing_id: '||rec.passing_id ||' Exception details: '||substr(SQLERRM, 1, 3500));
                rollback;
                log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - transaction rolled back');
                continue;
                log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - continue archiving');
             end;
          end loop;


          v_exec_time:= (dbms_utility.get_time - v_exec_time) / 100;
          log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - number of archived passings: '||v_archived_passings);
          log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - number of archived presumptions: '||v_archived_presumptions);
          log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - number of archived  medias: '||v_archived_medias);
          log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - stored procedure finished successfully');
          log_success(c_proc_name, 'INFO', 'ARCHIVE_DATA - execution time: '|| round(v_exec_time, 2) || ' seconds');

      end if;

      exception 
       when others then
        log_error(c_proc_name, 'ERROR', substr(SQLERRM, 1, 4000));
        rollback;
        log_success(c_proc_name, 'END', 'ARCHIVE_DATA - transaction rolled back');

  END archive_data;
  */
  -- ===============================================================================================================================================================

	procedure purge_recycle_bin is
		c_proc_name constant varchar2(30) := 'PURGE_RECYCLE_BIN';
	begin
		log_success(
		           c_proc_name,
		           'BEGIN',
		           'recycle bin cleanup started'
		);
		for rec in (
			select object_name,
			       type
			  from recyclebin
			 where to_date(droptime,
        'YYYY-MM-DD:HH24:MI:SS') < sysdate - 365
		) loop
			begin
				if rec.type = 'INDEX' then
					execute_sql(
					           c_proc_name,
					           'RECYCLEBIN',
					           'PURGE INDEX "'
					           || rec.object_name
					           || '"'
					);
				elsif rec.type = 'TABLE' then
					execute_sql(
					           c_proc_name,
					           'RECYCLEBIN',
					           'PURGE TABLE "'
					           || rec.object_name
					           || '"'
					);
				elsif rec.type = 'Table Partition' then
					execute_sql(
					           c_proc_name,
					           'RECYCLEBIN',
					           'PURGE TABLE "'
					           || rec.object_name
					           || '"'
					);
				end if;

			end;
		end loop;

		log_success(
		           c_proc_name,
		           'END',
		           'recycle bin cleanup finished'
		);
	exception
		when others then
			log_error(
			         c_proc_name,
			         'ERROR',
			         substr(
			               sqlerrm,
			               1,
			               4000
			         )
			);
	end purge_recycle_bin;

  -- ===============================================================================================================================================================
-- procedure commented out by ronayp on 2024.06.02. : ksh_kkep_report_portal table missing
/*
PROCEDURE forgfer_report(p_date IN DATE, p_directory IN VARCHAR) IS
    c_proc_name               CONSTANT VARCHAR2(30) := 'FORGFER_REPORT';
    c_date_format             CONSTANT VARCHAR2(21) := 'YYYY.MM.DD HH24:MI:SS';
    v_report_date_from        DATE;
    v_report_date_to          DATE;
    v_report_file_size        NUMBER;
    v_report_file_blocksize   NUMBER;
    v_report_file_name        VARCHAR2(100);
    v_report_file_exist       BOOLEAN;
    v_report_file             UTL_FILE.FILE_TYPE;
  BEGIN
    v_report_date_from := trunc(p_date);
    v_report_date_to := v_report_date_from + 1;

    log_success(c_proc_name, 'BEGIN', 'start FORGFER report from [' || v_report_date_from || '] to ['|| v_report_date_to ||']');

    v_report_file_name:=  'ORFK_'|| to_char(v_report_date_from, 'YYYY-MM-DD') || '.csv';
    utl_file.fgetattr(p_directory, v_report_file_name, v_report_file_exist, v_report_file_size, v_report_file_blocksize);

    -- Deletes report file if already exists
    IF v_report_file_exist THEN
      UTL_FILE.fremove(p_directory, v_report_file_name);
    END IF;

    v_report_file := UTL_FILE.FOPEN(p_directory, v_report_file_name, 'w');

    FOR rec IN  (SELECT 
        nvl(t.portal_id, p2.portal_id) as portal_id,
        s.lane,
        CASE p.country_code WHEN 'H' THEN 'H' ELSE '' END as country_code,
        to_char(p.at_timestamp, c_date_format) as at_time,
        p.kkep_vehicle_category,
        p.direction
      FROM passing p 
        LEFT JOIN kkep_report r on (p.kkepreport_id = r.id)
        LEFT JOIN kkep_device d ON (d.device_id       = r.device_id)
        LEFT JOIN kkep_portal p2 ON (d.kkep_portal_id  = p2.id)
        LEFT JOIN spot s ON (r.spot_id = s.id) 
        LEFT JOIN ksh_kkep_report_portal t ON (p.kkepreport_id = t.kkepreport_id)
      WHERE d.device_type = 'FIX'
          AND p.created_at between v_report_date_from AND v_report_date_to + 1/24
          AND p.at_timestamp between v_report_date_from AND v_report_date_to
      ORDER BY p.at_timestamp ASC)
      LOOP
        UTL_FILE.PUT(v_report_file, rec.portal_id||';'||rec.lane||';'||rec.country_code||';'||rec.at_time||';'||rec.kkep_vehicle_category||';'||rec.direction);

        UTL_FILE.NEW_LINE(v_report_file);
      END LOOP;
      UTL_FILE.FCLOSE(v_report_file);

      log_success(c_proc_name, 'END', 'finish FORGFER report');

      EXCEPTION
        WHEN OTHERS THEN
          log_error(c_proc_name, 'ERROR', substr(SQLERRM, 1, 4000));
  END forgfer_report;
  */
 -- ===============================================================================================================================================================

	procedure safety_belt_report (
		p_directory in varchar
	) is

		c_proc_name             constant varchar2(30) := 'SAFETY_BELT_REPORT';
		c_open_to_write         constant varchar2(1) := 'w';
		c_open_to_append        constant varchar2(1) := 'a';
		c_day_format            constant varchar2(21) := 'YYYY.MM.DD.';
		c_partition_day         constant varchar2(21) := 'YYYYMMDD';
		c_pres_strength         constant varchar2(10) := 'STRONG';
		c_biz                   constant varchar2(10) := 'BIZ';
		c_vh_kkep               constant varchar2(10) := '114%';
		c_nulla                 constant varchar2(10) := '0';
		c_vesszo                constant varchar2(10) := '||:||';
		c_konfidencia           constant varchar2(21) := 'KONFIDENCIASZINT';
		v_partition_name        varchar(100);
		v_day_name              varchar(100);
		v_report_date           date;
		v_report_file_size      number;
		v_report_file_blocksize number;
		v_report_file_name      varchar(100);
		v_report_file_exist     boolean;
		v_report_file           utl_file.file_type;
		v_stmt_str              varchar2(4000);
		cur                     sys_refcursor;
		type row_type is record (
				nap               varchar2(255),
				portal_id         varchar2(255),
				lane              varchar2(255),
				device_id         varchar2(255),
				report_created_at varchar2(255),
				uzemido           varchar2(255),
				konfidenciaszint  number,
				maxvelelem        number,
				elhaladas_szam    number,
				velelem_szam      number,
				gyenge_velelem    number
		);
		row                     row_type;
	begin
		v_report_date      := sysdate - 1;
		v_partition_name   := 'P' || to_char(
		                                  v_report_date,
		                                  c_partition_day
		                           );
		v_day_name         := to_char(
		                     v_report_date,
		                     c_partition_day
		              );
		v_stmt_str         := 'select nap,portal_id,lane,device_id,report_created_At,
lpad(floor( sum(uzem) / 3600), 2,''0'') ||'':''|| 
lpad(mod(floor(sum(uzem)/ 60), 60), 2,''0'') ||'':''||
lpad(mod(floor(sum(uzem)/ 1), 60), 2,''0'')  as uzemido,
max (konfidenciaszint) as konfidenciaszint,max(maxvelelem) as maxvelelem,
sum(elhaladas) as Elhaladas_szam,  sum(velelem) as Velelem_szam,   sum(gyenge_velelem) as gyenge_velelem
from (select 
   to_char(kr.Created_at,''YYYY.MM.DD.'') as nap,
   KP.PORTAL_ID,
   S.LANE,
   kr.device_id ,
   to_char(kr.Created_at,''YYYY.MM.DD. HH24:MI:SS'') as report_created_At,
   round((((extract(day from finished_at-start_at) * 60 * 60 * 24 +
    extract (hour from finished_at-start_at) * 60 * 60 +
    extract (minute from finished_at-start_at) * 60 +
    extract (second from finished_at-start_at)))),1) as Uzem,
  max(case when sr.function_subtype=''KONFIDENCIASZINT'' then sr.restriction_value end) as konfidenciaszint,
  max(case when sk.function_subtype=''MAX_VELELEMSZAM'' then sk.restriction_value end) as maxvelelem,
  (count(distinct p.id)) as elhaladas,
   count(distinct(case when PR.kafir_presumption_strength =''STRONG'' and pr.KKEP_FUNCTION=''BIZ'' then pr.id end)) as velelem  ,
   count(distinct(case when PR.kafir_presumption_strength =''WEAK'' and pr.KKEP_FUNCTION=''BIZ'' then pr.id end)) as gyenge_velelem  
  from kkep_report kr  
  join spot s on  KR.SPOT_ID=s.id
  join spot_restriction sr on s.id=sr.spot_id
    join  spot_restriction sk on s.id=sk.spot_id and SK.FUNCTION_SUBTYPE!= SR.FUNCTION_SUBTYPE
  join kkep_device kd on kd.device_id=kr.device_id
  join KKEP_PORTAL kp on kp.id=KD.KKEP_PORTAL_ID
  left join passing      partition ('
		              || v_partition_name
		              || ') p on p.kkepreport_id=kr.id
  left join presumption  partition ('
		              || v_partition_name
		              || ') pr on pr.passing_id=p.id

  where  ((trunc(kr.created_at)=TO_DATE('
		              || v_day_name
		              || ',''YYYYMMDD'')) or 
         (trunc(kr.finished_at)=TO_DATE('
		              || v_day_name
		              || ',''YYYYMMDD'')) ) and
          sr.function_type=''BIZ''        and sk.function_type=''BIZ''
  and kr.device_id not like ''114%''
  group by to_char(kr.Created_at,''YYYY.MM.DD.''),  KP.PORTAL_ID,s.lane,kr.device_id,to_char(kr.Created_at,''YYYY.MM.DD. HH24:MI:SS''),(finished_at-start_at)  
              ,sr.function_subtype,sr.restriction_value ,sk.function_subtype,sk.restriction_value
  order by nap,portal_id,s.lane,kr.device_id asc    )
where konfidenciaszint is not null
group by nap,portal_id,lane,device_id,report_created_At    ,konfidenciaszint,maxvelelem 
order by nap,portal_id,lane,device_id,report_created_At asc';

		dbms_output.put_line(v_stmt_str);
    /* Create file  */

		v_report_file_name := 'ORFK_BIZ_ESEMENYEK_'
		                      || to_char(
		                                v_report_date,
		                                'YYYY-MM-DD'
		                         )
		                      || '.csv';
		utl_file.fgetattr(
		                 p_directory,
		                 v_report_file_name,
		                 v_report_file_exist,
		                 v_report_file_size,
		                 v_report_file_blocksize
		);
		dbms_output.put_line('CSV file path:'
		                     || p_directory
		                     || v_report_file_name);

    /* Add header if file is new, append to file if it already exists */
		if v_report_file_exist then
			v_report_file := utl_file.fopen(
			                               p_directory,
			                               v_report_file_name,
			                               c_open_to_append
			                 );
		else
			v_report_file := utl_file.fopen(
			                               p_directory,
			                               v_report_file_name,
			                               c_open_to_write
			                 );
			utl_file.put(
			            v_report_file,
			            'Nap;Portal azonosito;Sav;Eszkoz azonosito;KKEP_report_inditas;Uzemido;Konfidenciaszint;Max velelemszam;Elhaladasok szama;Velelmek szama;Gyenge velelem'
			);
			utl_file.new_line(v_report_file);
		end if;

    /* Add lines to csv based on the select result */
		open cur for v_stmt_str;

		loop
			fetch cur into row;
			exit when cur%notfound;
			utl_file.put(
			            v_report_file,
			            row.nap
			            || ';'
			            || row.portal_id
			            || ';'
			            || row.lane
			            || ';'
			            || row.device_id
			            || ';'
			            || row.report_created_at
			            || ';'
			            || row.uzemido
			            || ';'
			            || row.konfidenciaszint
			            || ';'
			            || row.maxvelelem
			            || ';'
			            || row.elhaladas_szam
			            || ';'
			            || row.velelem_szam
			            || ';'
			            || row.gyenge_velelem
			            || ';'
			);

			utl_file.new_line(v_report_file);
		end loop;

		close cur;
    /* Close opened file*/
		utl_file.fclose(v_report_file);
		dbms_output.put_line('File Closed');
	end safety_belt_report;

-- ===============================================================================================================================================================

end kafir_util;