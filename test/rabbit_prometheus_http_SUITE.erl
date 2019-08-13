%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2016-2019 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_prometheus_http_SUITE).

-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_mgmt_test.hrl").

-compile(export_all).

all() ->
    [
     {group, default_config},
     {group, config_path},
     {group, config_port},
     {group, with_metrics}
    ].

groups() ->
    [
     {default_config, [], all_tests()},
     {config_path, [], all_tests()},
     {config_port, [], all_tests()},
     {with_metrics, [], [metrics_test, metrics_global_labels_test]}
    ].

all_tests() ->
    [
     get_test,
     content_type_test,
     encoding_test,
     gzip_encoding_test
    ].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------
init_per_group(default_config, Config) ->
    init_per_group(default_config, Config, []);
init_per_group(config_path, Config0) ->
    PathConfig = {rabbitmq_prometheus, [{path, "/bunnieshop"}]},
    Config1 = rabbit_ct_helpers:merge_app_env(Config0, PathConfig),
    init_per_group(config_path, Config1, [{prometheus_path, "/bunnieshop"}]);
init_per_group(config_port, Config0) ->
    PathConfig = {rabbitmq_prometheus, [{tcp_config, [{port, 15674}]}]},
    Config1 = rabbit_ct_helpers:merge_app_env(Config0, PathConfig),
    init_per_group(config_port, Config1, [{prometheus_port, 15674}]);
init_per_group(with_metrics, Config0) ->
    Config1 = rabbit_ct_helpers:merge_app_env(
        Config0,
        [{rabbit, [{collect_statistics, coarse}, {collect_statistics_interval, 100}]}]
    ),
    Config2 = rabbit_ct_helpers:merge_app_env(
        Config1,
        {prometheus, [{global_labels, [{node, node()}, {cluster, "rabbitmq_prometheus_test"},
                                       {rabbitmq_version, "3.8.0+beta.5"},
                                       {erlang_version, "21.3"}]}]}
    ),
    Config3 = init_per_group(with_metrics, Config2, []),
    ok = rabbit_ct_broker_helpers:enable_feature_flag(Config3, quorum_queue),

    A = rabbit_ct_broker_helpers:get_node_config(Config3, 0, nodename),
    Ch = rabbit_ct_client_helpers:open_channel(Config3, A),

    Q = <<"prometheus_test_queue">>,
    amqp_channel:call(Ch,
                      #'queue.declare'{queue = Q,
                                       durable = true,
                                       arguments = [{<<"x-queue-type">>, longstr, <<"quorum">>}]
                                      }),
    amqp_channel:cast(Ch,
                      #'basic.publish'{routing_key = Q},
                      #amqp_msg{payload = <<"msg">>}),
    timer:sleep(150),
    {#'basic.get_ok'{}, #amqp_msg{}} = amqp_channel:call(Ch, #'basic.get'{queue = Q}),
    timer:sleep(10000),

    Config3 ++ [{channel_pid, Ch}, {queue_name, Q}].

init_per_group(Group, Config0, Extra) ->
    rabbit_ct_helpers:log_environment(),
    inets:start(),
    NodeConf = [{rmq_nodename_suffix, Group}] ++ Extra,
    Config1 = rabbit_ct_helpers:set_config(Config0, NodeConf),
    rabbit_ct_helpers:run_setup_steps(Config1, rabbit_ct_broker_helpers:setup_steps()
                                      ++ rabbit_ct_client_helpers:setup_steps()).

end_per_group(with_metrics, Config) ->
    Ch = ?config(channel_pid, Config),
    amqp_channel:call(Ch, #'queue.delete'{queue = ?config(queue_name, Config)}),
    rabbit_ct_client_helpers:close_channel(Ch),
    end_per_group_(Config);
end_per_group(_, Config) ->
    end_per_group_(Config).

end_per_group_(Config) ->
    inets:stop(),
    rabbit_ct_helpers:run_teardown_steps(Config, rabbit_ct_client_helpers:teardown_steps()
                                         ++ rabbit_ct_broker_helpers:teardown_steps()).

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% -------------------------------------------------------------------
%% Testcases.
%% -------------------------------------------------------------------

get_test(Config) ->
    {_Headers, Body} = http_get(Config, [], 200),
    %% Let's check that the body looks like a valid response
    ?assertEqual(match, re:run(Body, "TYPE", [{capture, none}])),
    Port = proplists:get_value(prometheus_port, Config, 15692),
    URI = lists:flatten(io_lib:format("http://localhost:~p/metricsooops", [Port])),
    {ok, {{_, CodeAct, _}, _, _}} = httpc:request(get, {URI, []}, ?HTTPC_OPTS, []),
    ?assertMatch(404, CodeAct).

content_type_test(Config) ->
    {Headers, Body} = http_get(Config, [{"accept", "text/plain"}], 200),
    ?assertEqual(match, re:run(proplists:get_value("content-type", Headers),
                               "text/plain", [{capture, none}])),
    %% Let's check that the body looks like a valid response
    ?assertEqual(match, re:run(Body, "TYPE", [{capture, none}])),

    http_get(Config, [{"accept", "text/plain, text/html"}], 200),
    http_get(Config, [{"accept", "*/*"}], 200),
    http_get(Config, [{"accept", "text/xdvi"}], 406),
    http_get(Config, [{"accept", "application/vnd.google.protobuf"}], 406).

encoding_test(Config) ->
    {Headers, Body} = http_get(Config, [{"accept-encoding", "deflate"}], 200),
    ?assertMatch("identity", proplists:get_value("content-encoding", Headers)),
    ?assertEqual(match, re:run(Body, "TYPE", [{capture, none}])).

gzip_encoding_test(Config) ->
    {Headers, Body} = http_get(Config, [{"accept-encoding", "gzip"}], 200),
    ?assertMatch("gzip", proplists:get_value("content-encoding", Headers)),
    %% If the body is not gzip, zlib:gunzip will crash
    ?assertEqual(match, re:run(zlib:gunzip(Body), "TYPE", [{capture, none}])).

metrics_test(Config) ->
    {_Headers, Body} = http_get(Config, [], 200),
    %% Checking that the body looks like a valid response
    ct:pal(Body),
    ?assertEqual(match, re:run(Body, "TYPE", [{capture, none}])),
    ?assertEqual(match, re:run(Body, ?config(queue_name, Config), [{capture, none}])),
    %% Checking that we have the first metric from each ETS table owned by rabbitmq_metrics
    ?assertEqual(match, re:run(Body, "rabbitmq_channel_consumers{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_channel_messages_published{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_erlang_process_reductions_total{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_channel_get_ack_total{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_connection_opened_total{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_connection_incoming_bytes_total{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_connection_incoming_packets_total{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_queue_messages_published_total{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_file_descriptors_open{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_file_descriptors_open_limit{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_io_read_ops_total{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_raft_term{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_queue_messages_ready{", [{capture, none}])),
    ?assertEqual(match, re:run(Body, "rabbitmq_queue_consumers{", [{capture, none}])),
    %% Checking the first TOTALS metric
    ?assertEqual(match, re:run(Body, "rabbitmq_connections", [{capture, none}])).

metrics_global_labels_test(Config) ->
    {_Headers, Body} = http_get(Config, [], 200),
    Lines = string:split(Body, "\n", all),
    [
        begin
            case string:str(Line, "node=") of
                0 -> ct:fail("node label missing from metric '~s'", [Line]);
                _ -> ok
            end,
            case string:str(Line, "cluster=") of
                0 -> ct:fail("cluster label missing from metric '~s'", [Line]);
                _ -> ok
            end,
            case string:str(Line, "rabbitmq_version=") of
                0 -> ct:fail("rabbitmq_version label missing from metric '~s'", [Line]);
                _ -> ok
            end,
            case string:str(Line, "erlang_version=") of
                0 -> ct:fail("erlang_version label missing from metric '~s'", [Line]);
                _ -> ok
            end
        end
        ||
        Line <- Lines,
        lists:prefix("#", Line) == false,
        Line /= ""
    ].

http_get(Config, ReqHeaders, CodeExp) ->
    Path = proplists:get_value(prometheus_path, Config, "/metrics"),
    Port = proplists:get_value(prometheus_port, Config, 15692),
    URI = lists:flatten(io_lib:format("http://localhost:~p~s", [Port, Path])),
    {ok, {{_HTTP, CodeAct, _}, Headers, Body}} =
        httpc:request(get, {URI, ReqHeaders}, ?HTTPC_OPTS, []),
    ?assertMatch(CodeExp, CodeAct),
    {Headers, Body}.
