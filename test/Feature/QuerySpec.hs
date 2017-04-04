module Feature.QuerySpec where

import Test.Hspec hiding (pendingWith)
import Test.Hspec.Wai
import Test.Hspec.Wai.JSON
import Network.HTTP.Types
import Network.Wai.Test (SResponse(simpleHeaders,simpleStatus,simpleBody))
import qualified Data.ByteString.Lazy as BL (empty)

import SpecHelper
import Text.Heredoc
import Network.Wai (Application)

import Protolude hiding (get)

spec :: SpecWith Application
spec = do

  describe "Querying a table with a column called count" $
    it "should not confuse count column with pg_catalog.count aggregate" $
      get "/has_count_column" `shouldRespondWith` 200

  describe "Querying a table with a column called t" $
    it "should not conflict with internal postgrest table alias" $
      get "/clashing_column?select=t" `shouldRespondWith` 200

  describe "Querying a nonexistent table" $
    it "causes a 404" $
      get "/faketable" `shouldRespondWith` 404

  describe "Filtering response" $ do
    it "matches with equality" $
      get "/items?id=eq.5"
        `shouldRespondWith` [json| [{"id":5}] |]
        { matchHeaders = ["Content-Range" <:> "0-0/*"] }

    it "matches with equality using not operator" $
      get "/items?id=not.eq.5"
        `shouldRespondWith` [json| [{"id":1},{"id":2},{"id":3},{"id":4},{"id":6},{"id":7},{"id":8},{"id":9},{"id":10},{"id":11},{"id":12},{"id":13},{"id":14},{"id":15}] |]
        { matchHeaders = ["Content-Range" <:> "0-13/*"] }

    it "matches with more than one condition using not operator" $
      get "/simple_pk?k=like.*yx&extra=not.eq.u" `shouldRespondWith` "[]"

    it "matches with inequality using not operator" $ do
      get "/items?id=not.lt.14&order=id.asc"
        `shouldRespondWith` [json| [{"id":14},{"id":15}] |]
        { matchHeaders = ["Content-Range" <:> "0-1/*"] }
      get "/items?id=not.gt.2&order=id.asc"
        `shouldRespondWith` [json| [{"id":1},{"id":2}] |]
        { matchHeaders = ["Content-Range" <:> "0-1/*"] }

    it "matches items IN" $
      get "/items?id=in.1,3,5"
        `shouldRespondWith` [json| [{"id":1},{"id":3},{"id":5}] |]
        { matchHeaders = ["Content-Range" <:> "0-2/*"] }

    it "matches items NOT IN" $
      get "/items?id=notin.2,4,6,7,8,9,10,11,12,13,14,15"
        `shouldRespondWith` [json| [{"id":1},{"id":3},{"id":5}] |]
        { matchHeaders = ["Content-Range" <:> "0-2/*"] }

    it "matches items NOT IN using not operator" $
      get "/items?id=not.in.2,4,6,7,8,9,10,11,12,13,14,15"
        `shouldRespondWith` [json| [{"id":1},{"id":3},{"id":5}] |]
        { matchHeaders = ["Content-Range" <:> "0-2/*"] }

    it "matches nulls using not operator" $
      get "/no_pk?a=not.is.null" `shouldRespondWith`
        [json| [{"a":"1","b":"0"},{"a":"2","b":"0"}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "matches nulls in varchar and numeric fields alike" $ do
      get "/no_pk?a=is.null" `shouldRespondWith`
        [json| [{"a": null, "b": null}] |]
        { matchHeaders = [matchContentTypeJson] }

      get "/nullable_integer?a=is.null" `shouldRespondWith` [str|[{"a":null}]|]

    it "matches with like" $ do
      get "/simple_pk?k=like.*yx" `shouldRespondWith`
        [str|[{"k":"xyyx","extra":"u"}]|]
      get "/simple_pk?k=like.xy*" `shouldRespondWith`
        [str|[{"k":"xyyx","extra":"u"}]|]
      get "/simple_pk?k=like.*YY*" `shouldRespondWith`
        [str|[{"k":"xYYx","extra":"v"}]|]

    it "matches with like using not operator" $
      get "/simple_pk?k=not.like.*yx" `shouldRespondWith`
        [str|[{"k":"xYYx","extra":"v"}]|]

    it "matches with ilike" $ do
      get "/simple_pk?k=ilike.xy*&order=extra.asc" `shouldRespondWith`
        [str|[{"k":"xyyx","extra":"u"},{"k":"xYYx","extra":"v"}]|]
      get "/simple_pk?k=ilike.*YY*&order=extra.asc" `shouldRespondWith`
        [str|[{"k":"xyyx","extra":"u"},{"k":"xYYx","extra":"v"}]|]

    it "matches with ilike using not operator" $
      get "/simple_pk?k=not.ilike.xy*&order=extra.asc" `shouldRespondWith` "[]"

    it "matches with tsearch @@" $
      get "/tsearch?text_search_vector=@@.foo" `shouldRespondWith`
        [json| [{"text_search_vector":"'bar':2 'foo':1"}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "matches with tsearch @@ using not operator" $
      get "/tsearch?text_search_vector=not.@@.foo" `shouldRespondWith`
        [json| [{"text_search_vector":"'baz':1 'qux':2"}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "matches with computed column" $
      get "/items?always_true=eq.true&order=id.asc" `shouldRespondWith`
        [json| [{"id":1},{"id":2},{"id":3},{"id":4},{"id":5},{"id":6},{"id":7},{"id":8},{"id":9},{"id":10},{"id":11},{"id":12},{"id":13},{"id":14},{"id":15}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "order by computed column" $
      get "/items?order=anti_id.desc" `shouldRespondWith`
        [json| [{"id":1},{"id":2},{"id":3},{"id":4},{"id":5},{"id":6},{"id":7},{"id":8},{"id":9},{"id":10},{"id":11},{"id":12},{"id":13},{"id":14},{"id":15}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "matches filtering nested items 2" $
      get "/clients?select=id,projects{id,tasks2{id,name}}&projects.tasks.name=like.Design*"
        `shouldRespondWith` [json| {"message":"Could not find foreign keys between these entities, No relation found between projects and tasks2"}|]
        { matchStatus  = 400
        , matchHeaders = [matchContentTypeJson]
        }

    it "matches filtering nested items" $
      get "/clients?select=id,projects{id,tasks{id,name}}&projects.tasks.name=like.Design*" `shouldRespondWith`
        [str|[{"id":1,"projects":[{"id":1,"tasks":[{"id":1,"name":"Design w7"}]},{"id":2,"tasks":[{"id":3,"name":"Design w10"}]}]},{"id":2,"projects":[{"id":3,"tasks":[{"id":5,"name":"Design IOS"}]},{"id":4,"tasks":[{"id":7,"name":"Design OSX"}]}]}]|]

    it "matches with @> operator" $
      get "/complex_items?select=id&arr_data=@>.{2}" `shouldRespondWith`
        [str|[{"id":2},{"id":3}]|]

    it "matches with <@ operator" $
      get "/complex_items?select=id&arr_data=<@.{1,2,4}" `shouldRespondWith`
        [str|[{"id":1},{"id":2}]|]


  describe "Shaping response with select parameter" $ do

    it "selectStar works in absense of parameter" $
      get "/complex_items?id=eq.3" `shouldRespondWith`
        [str|[{"id":3,"name":"Three","settings":{"foo":{"int":1,"bar":"baz"}},"arr_data":[1,2,3],"field-with_sep":1}]|]

    it "dash `-` in column names is accepted" $
      get "/complex_items?id=eq.3&select=id,field-with_sep" `shouldRespondWith`
        [str|[{"id":3,"field-with_sep":1}]|]

    it "one simple column" $
      get "/complex_items?select=id" `shouldRespondWith`
        [json| [{"id":1},{"id":2},{"id":3}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "rename simple column" $
      get "/complex_items?id=eq.1&select=myId:id" `shouldRespondWith`
        [json| [{"myId":1}] |]
        { matchHeaders = [matchContentTypeJson] }


    it "one simple column with casting (text)" $
      get "/complex_items?select=id::text" `shouldRespondWith`
        [json| [{"id":"1"},{"id":"2"},{"id":"3"}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "rename simple column with casting" $
      get "/complex_items?id=eq.1&select=myId:id::text" `shouldRespondWith`
        [json| [{"myId":"1"}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "json column" $
      get "/complex_items?id=eq.1&select=settings" `shouldRespondWith`
        [json| [{"settings":{"foo":{"int":1,"bar":"baz"}}}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "json subfield one level with casting (json)" $
      get "/complex_items?id=eq.1&select=settings->>foo::json" `shouldRespondWith`
        [json| [{"foo":{"int":1,"bar":"baz"}}] |] -- the value of foo here is of type "text"
        { matchHeaders = [matchContentTypeJson] }

    it "rename json subfield one level with casting (json)" $
      get "/complex_items?id=eq.1&select=myFoo:settings->>foo::json" `shouldRespondWith`
        [json| [{"myFoo":{"int":1,"bar":"baz"}}] |] -- the value of foo here is of type "text"
        { matchHeaders = [matchContentTypeJson] }

    it "fails on bad casting (data of the wrong format)" $
      get "/complex_items?select=settings->foo->>bar::integer"
        `shouldRespondWith` [json| {"hint":null,"details":null,"code":"22P02","message":"invalid input syntax for integer: \"baz\""} |]
        { matchStatus  = 400
        , matchHeaders = []
        }

    it "fails on bad casting (wrong cast type)" $
      get "/complex_items?select=id::fakecolumntype"
        `shouldRespondWith` [json| {"hint":null,"details":null,"code":"42704","message":"type \"fakecolumntype\" does not exist"} |]
        { matchStatus  = 400
        , matchHeaders = []
        }


    it "json subfield two levels (string)" $
      get "/complex_items?id=eq.1&select=settings->foo->>bar" `shouldRespondWith`
        [json| [{"bar":"baz"}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "rename json subfield two levels (string)" $
      get "/complex_items?id=eq.1&select=myBar:settings->foo->>bar" `shouldRespondWith`
        [json| [{"myBar":"baz"}] |]
        { matchHeaders = [matchContentTypeJson] }


    it "json subfield two levels with casting (int)" $
      get "/complex_items?id=eq.1&select=settings->foo->>int::integer" `shouldRespondWith`
        [json| [{"int":1}] |] -- the value in the db is an int, but here we expect a string for now
        { matchHeaders = [matchContentTypeJson] }

    it "rename json subfield two levels with casting (int)" $
      get "/complex_items?id=eq.1&select=myInt:settings->foo->>int::integer" `shouldRespondWith`
        [json| [{"myInt":1}] |] -- the value in the db is an int, but here we expect a string for now
        { matchHeaders = [matchContentTypeJson] }

    it "requesting parents and children" $
      get "/projects?id=eq.1&select=id, name, clients{*}, tasks{id, name}" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","clients":{"id":1,"name":"Microsoft"},"tasks":[{"id":1,"name":"Design w7"},{"id":2,"name":"Code w7"}]}]|]

    it "embed data with two fk pointing to the same table" $
      get "/orders?id=eq.1&select=id, name, billing_address_id{id}, shipping_address_id{id}" `shouldRespondWith`
        [str|[{"id":1,"name":"order 1","billing_address_id":{"id":1},"shipping_address_id":{"id":2}}]|]


    it "requesting parents and children while renaming them" $
      get "/projects?id=eq.1&select=myId:id, name, project_client:client_id{*}, project_tasks:tasks{id, name}" `shouldRespondWith`
        [str|[{"myId":1,"name":"Windows 7","project_client":{"id":1,"name":"Microsoft"},"project_tasks":[{"id":1,"name":"Design w7"},{"id":2,"name":"Code w7"}]}]|]

    it "requesting parents two levels up while using FK to specify the link" $
      get "/tasks?id=eq.1&select=id,name,project:project_id{id,name,client:client_id{id,name}}" `shouldRespondWith`
        [str|[{"id":1,"name":"Design w7","project":{"id":1,"name":"Windows 7","client":{"id":1,"name":"Microsoft"}}}]|]

    it "requesting parents two levels up while using FK to specify the link (with rename)" $
      get "/tasks?id=eq.1&select=id,name,project:project_id{id,name,client:client_id{id,name}}" `shouldRespondWith`
        [str|[{"id":1,"name":"Design w7","project":{"id":1,"name":"Windows 7","client":{"id":1,"name":"Microsoft"}}}]|]


    it "requesting parents and filtering parent columns" $
      get "/projects?id=eq.1&select=id, name, clients{id}" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","clients":{"id":1}}]|]

    it "rows with missing parents are included" $
      get "/projects?id=in.1,5&select=id,clients{id}" `shouldRespondWith`
        [str|[{"id":1,"clients":{"id":1}},{"id":5,"clients":null}]|]

    it "rows with no children return [] instead of null" $
      get "/projects?id=in.5&select=id,tasks{id}" `shouldRespondWith`
        [str|[{"id":5,"tasks":[]}]|]

    it "requesting children 2 levels" $
      get "/clients?id=eq.1&select=id,projects{id,tasks{id}}" `shouldRespondWith`
        [str|[{"id":1,"projects":[{"id":1,"tasks":[{"id":1},{"id":2}]},{"id":2,"tasks":[{"id":3},{"id":4}]}]}]|]

    it "requesting many<->many relation" $
      get "/tasks?select=id,users{id}" `shouldRespondWith`
        [str|[{"id":1,"users":[{"id":1},{"id":3}]},{"id":2,"users":[{"id":1}]},{"id":3,"users":[{"id":1}]},{"id":4,"users":[{"id":1}]},{"id":5,"users":[{"id":2},{"id":3}]},{"id":6,"users":[{"id":2}]},{"id":7,"users":[{"id":2}]},{"id":8,"users":[]}]|]

    it "requesting many<->many relation with rename" $
      get "/tasks?id=eq.1&select=id,theUsers:users{id}" `shouldRespondWith`
        [str|[{"id":1,"theUsers":[{"id":1},{"id":3}]}]|]


    it "requesting many<->many relation reverse" $
      get "/users?select=id,tasks{id}" `shouldRespondWith`
        [str|[{"id":1,"tasks":[{"id":1},{"id":2},{"id":3},{"id":4}]},{"id":2,"tasks":[{"id":5},{"id":6},{"id":7}]},{"id":3,"tasks":[{"id":1},{"id":5}]}]|]

    it "requesting parents and children on views" $
      get "/projects_view?id=eq.1&select=id, name, clients{*}, tasks{id, name}" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","clients":{"id":1,"name":"Microsoft"},"tasks":[{"id":1,"name":"Design w7"},{"id":2,"name":"Code w7"}]}]|]

    it "requesting parents and children on views with renamed keys" $
      get "/projects_view_alt?t_id=eq.1&select=t_id, name, clients{*}, tasks{id, name}" `shouldRespondWith`
        [str|[{"t_id":1,"name":"Windows 7","clients":{"id":1,"name":"Microsoft"},"tasks":[{"id":1,"name":"Design w7"},{"id":2,"name":"Code w7"}]}]|]


    it "requesting children with composite key" $
      get "/users_tasks?user_id=eq.2&task_id=eq.6&select=*, comments{content}" `shouldRespondWith`
        [str|[{"user_id":2,"task_id":6,"comments":[{"content":"Needs to be delivered ASAP"}]}]|]

    it "detect relations in views from exposed schema that are based on tables in private schema and have columns renames" $
      get "/articles?id=eq.1&select=id,articleStars{users{*}}" `shouldRespondWith`
        [str|[{"id":1,"articleStars":[{"users":{"id":1,"name":"Angela Martin"}},{"users":{"id":2,"name":"Michael Scott"}},{"users":{"id":3,"name":"Dwight Schrute"}}]}]|]

    it "can select by column name" $
      get "/projects?id=in.1,3&select=id,name,client_id,client_id{id,name}" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","client_id":1,"client_id":{"id":1,"name":"Microsoft"}},{"id":3,"name":"IOS","client_id":2,"client_id":{"id":2,"name":"Apple"}}]|]

    it "can select by column name sans id" $
      get "/projects?id=in.1,3&select=id,name,client_id,client{id,name}" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","client_id":1,"client":{"id":1,"name":"Microsoft"}},{"id":3,"name":"IOS","client_id":2,"client":{"id":2,"name":"Apple"}}]|]

    it "can detect fk relations through views to tables in the public schema" $
      get "/consumers_view?select=*,orders_view{*}" `shouldRespondWith` 200


  describe "ordering response" $ do
    it "by a column asc" $
      get "/items?id=lte.2&order=id.asc"
        `shouldRespondWith` [json| [{"id":1},{"id":2}] |]
        { matchStatus  = 200
        , matchHeaders = ["Content-Range" <:> "0-1/*"]
        }
    it "by a column desc" $
      get "/items?id=lte.2&order=id.desc"
        `shouldRespondWith` [json| [{"id":2},{"id":1}] |]
        { matchStatus  = 200
        , matchHeaders = ["Content-Range" <:> "0-1/*"]
        }

    it "by a column with nulls first" $
      get "/no_pk?order=a.nullsfirst"
        `shouldRespondWith` [json| [{"a":null,"b":null},
                              {"a":"1","b":"0"},
                              {"a":"2","b":"0"}
                              ] |]
        { matchStatus = 200
        , matchHeaders = ["Content-Range" <:> "0-2/*"]
        }

    it "by a column asc with nulls last" $
      get "/no_pk?order=a.asc.nullslast"
        `shouldRespondWith` [json| [{"a":"1","b":"0"},
                              {"a":"2","b":"0"},
                              {"a":null,"b":null}] |]
        { matchStatus = 200
        , matchHeaders = ["Content-Range" <:> "0-2/*"]
        }

    it "by a column desc with nulls first" $
      get "/no_pk?order=a.desc.nullsfirst"
        `shouldRespondWith` [json| [{"a":null,"b":null},
                              {"a":"2","b":"0"},
                              {"a":"1","b":"0"}] |]
        { matchStatus = 200
        , matchHeaders = ["Content-Range" <:> "0-2/*"]
        }

    it "by a column desc with nulls last" $
      get "/no_pk?order=a.desc.nullslast"
        `shouldRespondWith` [json| [{"a":"2","b":"0"},
                              {"a":"1","b":"0"},
                              {"a":null,"b":null}] |]
        { matchStatus = 200
        , matchHeaders = ["Content-Range" <:> "0-2/*"]
        }

    it "by a json column property asc" $
      get "/json?order=data->>id.asc" `shouldRespondWith`
        [json| [{"data": {"id": 0}}, {"data": {"id": 1, "foo": {"bar": "baz"}}}, {"data": {"id": 3}}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "by a json column with two level property nulls first" $
      get "/json?order=data->foo->>bar.nullsfirst" `shouldRespondWith`
        [json| [{"data": {"id": 3}}, {"data": {"id": 0}}, {"data": {"id": 1, "foo": {"bar": "baz"}}}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "without other constraints" $
      get "/items?order=id.asc" `shouldRespondWith` 200

    it "ordering embeded entities" $
      get "/projects?id=eq.1&select=id, name, tasks{id, name}&tasks.order=name.asc" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","tasks":[{"id":2,"name":"Code w7"},{"id":1,"name":"Design w7"}]}]|]

    it "ordering embeded entities with alias" $
      get "/projects?id=eq.1&select=id, name, the_tasks:tasks{id, name}&tasks.order=name.asc" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","the_tasks":[{"id":2,"name":"Code w7"},{"id":1,"name":"Design w7"}]}]|]

    it "ordering embeded entities, two levels" $
      get "/projects?id=eq.1&select=id, name, tasks{id, name, users{id, name}}&tasks.order=name.asc&tasks.users.order=name.desc" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","tasks":[{"id":2,"name":"Code w7","users":[{"id":1,"name":"Angela Martin"}]},{"id":1,"name":"Design w7","users":[{"id":3,"name":"Dwight Schrute"},{"id":1,"name":"Angela Martin"}]}]}]|]

    it "ordering embeded parents does not break things" $
      get "/projects?id=eq.1&select=id, name, clients{id, name}&clients.order=name.asc" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","clients":{"id":1,"name":"Microsoft"}}]|]

    it "ordering embeded parents does not break things when using ducktape names" $
      get "/projects?id=eq.1&select=id, name, client{id, name}&client.order=name.asc" `shouldRespondWith`
        [str|[{"id":1,"name":"Windows 7","client":{"id":1,"name":"Microsoft"}}]|]



  describe "Accept headers" $ do
    it "should respond an unknown accept type with 415" $
      request methodGet "/simple_pk"
              (acceptHdrs "text/unknowntype") ""
        `shouldRespondWith` 415

    it "should respond correctly to */* in accept header" $
      request methodGet "/simple_pk"
              (acceptHdrs "*/*") ""
        `shouldRespondWith` 200

    it "*/* should rescue an unknown type" $
      request methodGet "/simple_pk"
              (acceptHdrs "text/unknowntype, */*") ""
        `shouldRespondWith` 200

    it "specific available preference should override */*" $ do
      r <- request methodGet "/simple_pk"
              (acceptHdrs "text/csv, */*") ""
      liftIO $ do
        let respHeaders = simpleHeaders r
        respHeaders `shouldSatisfy` matchHeader
          "Content-Type" "text/csv; charset=utf-8"

    it "honors client preference even when opposite of server preference" $ do
      r <- request methodGet "/simple_pk"
              (acceptHdrs "text/csv, application/json") ""
      liftIO $ do
        let respHeaders = simpleHeaders r
        respHeaders `shouldSatisfy` matchHeader
          "Content-Type" "text/csv; charset=utf-8"

    it "should respond correctly to multiple types in accept header" $
      request methodGet "/simple_pk"
              (acceptHdrs "text/unknowntype, text/csv") ""
        `shouldRespondWith` 200

    it "should respond with CSV to 'text/csv' request" $
      request methodGet "/simple_pk"
              (acceptHdrs "text/csv; version=1") ""
        `shouldRespondWith` "k,extra\nxyyx,u\nxYYx,v"
        { matchStatus  = 200
        , matchHeaders = ["Content-Type" <:> "text/csv; charset=utf-8"]
        }

  describe "Canonical location" $ do
    it "Sets Content-Location with alphabetized params" $
      get "/no_pk?b=eq.1&a=eq.1"
        `shouldRespondWith` "[]"
        { matchStatus  = 200
        , matchHeaders = ["Content-Location" <:> "/no_pk?a=eq.1&b=eq.1"]
        }

    it "Omits question mark when there are no params" $ do
      r <- get "/simple_pk"
      liftIO $ do
        let respHeaders = simpleHeaders r
        respHeaders `shouldSatisfy` matchHeader
          "Content-Location" "/simple_pk"

  describe "jsonb" $ do
    it "can filter by properties inside json column" $ do
      get "/json?data->foo->>bar=eq.baz" `shouldRespondWith`
        [json| [{"data": {"id": 1, "foo": {"bar": "baz"}}}] |]
        { matchHeaders = [matchContentTypeJson] }
      get "/json?data->foo->>bar=eq.fake" `shouldRespondWith`
        [json| [] |]
        { matchHeaders = [matchContentTypeJson] }
    it "can filter by properties inside json column using not" $
      get "/json?data->foo->>bar=not.eq.baz" `shouldRespondWith`
        [json| [] |]
        { matchHeaders = [matchContentTypeJson] }
    it "can filter by properties inside json column using ->>" $
      get "/json?data->>id=eq.1" `shouldRespondWith`
        [json| [{"data": {"id": 1, "foo": {"bar": "baz"}}}] |]
        { matchHeaders = [matchContentTypeJson] }

  describe "remote procedure call" $ do
    context "a proc that returns a set" $ do
      it "returns paginated results" $
        request methodPost "/rpc/getitemrange"
                (rangeHdrs (ByteRangeFromTo 0 0))  [json| { "min": 2, "max": 4 } |]
           `shouldRespondWith` [json| [{"id":3}] |]
            { matchStatus = 200
            , matchHeaders = ["Content-Range" <:> "0-0/*"]
            }

      it "includes total count if requested" $
        request methodPost "/rpc/getitemrange"
                (rangeHdrsWithCount (ByteRangeFromTo 0 0))
                [json| { "min": 2, "max": 4 } |]
           `shouldRespondWith` [json| [{"id":3}] |]
            { matchStatus = 206 -- it now knows the response is partial
            , matchHeaders = ["Content-Range" <:> "0-0/2"]
            }

      it "returns proper json" $
        post "/rpc/getitemrange" [json| { "min": 2, "max": 4 } |] `shouldRespondWith`
          [json| [ {"id": 3}, {"id":4} ] |]
          { matchHeaders = [matchContentTypeJson] }

    context "unknown function" $
      it "returns 404" $
        post "/rpc/fakefunc" [json| {} |] `shouldRespondWith` 404

    context "shaping the response returned by a proc" $ do
      it "returns a project" $
        post "/rpc/getproject" [json| { "id": 1} |] `shouldRespondWith`
          [str|[{"id":1,"name":"Windows 7","client_id":1}]|]

      it "can filter proc results" $
        post "/rpc/getallprojects?id=gt.1&id=lt.5&select=id" [json| {} |] `shouldRespondWith`
          [json|[{"id":2},{"id":3},{"id":4}]|]
          { matchHeaders = [matchContentTypeJson] }

      it "can limit proc results" $
        post "/rpc/getallprojects?id=gt.1&id=lt.5&select=id?limit=2&offset=1" [json| {} |]
          `shouldRespondWith` [json|[{"id":3},{"id":4}]|]
             { matchStatus = 200
             , matchHeaders = ["Content-Range" <:> "1-2/*"]
             }

      it "select works on the first level" $
        post "/rpc/getproject?select=id,name" [json| { "id": 1} |] `shouldRespondWith`
          [str|[{"id":1,"name":"Windows 7"}]|]

    context "foreign entities embedding" $ do
      it "can embed if related tables are in the exposed schema" $
        post "/rpc/getproject?select=id,name,client{id},tasks{id}" [json| { "id": 1} |] `shouldRespondWith`
          [str|[{"id":1,"name":"Windows 7","client":{"id":1},"tasks":[{"id":1},{"id":2}]}]|]

      it "cannot embed if the related table is not in the exposed schema" $
        post "/rpc/single_article?select=*,article_stars{*}" [json|{ "id": 1}|]
          `shouldRespondWith` 400

      it "can embed if the related tables are in a hidden schema but exposed as views" $
        post "/rpc/single_article?select=id,articleStars{userId}" [json|{ "id": 2}|]
          `shouldRespondWith` [json|[{"id": 2, "articleStars": [{"userId": 3}]}]|]
          { matchHeaders = [matchContentTypeJson] }

    context "a proc that returns an empty rowset" $
      it "returns empty json array" $
        post "/rpc/test_empty_rowset" [json| {} |] `shouldRespondWith`
          [json| [] |]
          { matchHeaders = [matchContentTypeJson] }

    context "proc return types" $ do
      context "returns text" $ do
        it "returns proper json" $
          post "/rpc/sayhello" [json| { "name": "world" } |] `shouldRespondWith`
            [json|"Hello, world"|]
            { matchHeaders = [matchContentTypeJson] }

        it "can handle unicode" $
          post "/rpc/sayhello" [json| { "name": "￥" } |] `shouldRespondWith`
            [json|"Hello, ￥"|]
            { matchHeaders = [matchContentTypeJson] }

      it "returns enum value" $
        post "/rpc/ret_enum" [json|{ "val": "foo" }|] `shouldRespondWith`
          [json|"foo"|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns domain value" $
        post "/rpc/ret_domain" [json|{ "val": "8" }|] `shouldRespondWith`
          [json|8|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns range" $
        post "/rpc/ret_range" [json|{ "low": 10, "up": 20 }|] `shouldRespondWith`
          [json|"[10,20)"|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns row of scalars" $
        post "/rpc/ret_scalars" [json|{}|] `shouldRespondWith`
          [json|[{"a":"scalars", "b":"foo", "c":1, "d":"[10,20)"}]|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns composite type in exposed schema" $
        post "/rpc/ret_point_2d" [json|{}|] `shouldRespondWith`
          [json|[{"x": 10, "y": 5}]|]
          { matchHeaders = [matchContentTypeJson] }

      it "cannot return composite type in hidden schema" $
        post "/rpc/ret_point_3d" [json|{}|] `shouldRespondWith` 401

      it "returns single row from table" $
        post "/rpc/single_article?select=id" [json|{"id": 2}|] `shouldRespondWith`
          [json|[{"id": 2}]|]
          { matchHeaders = [matchContentTypeJson] }

      it "returns null for void" $
        post "/rpc/ret_void" [json|{}|] `shouldRespondWith`
          [json|null|]
          { matchHeaders = [matchContentTypeJson] }

    context "improper input" $ do
      it "rejects unknown content type even if payload is good" $
        request methodPost "/rpc/sayhello"
          (acceptHdrs "audio/mpeg3") [json| { "name": "world" } |]
            `shouldRespondWith` 415
      it "rejects malformed json payload" $ do
        p <- request methodPost "/rpc/sayhello"
          (acceptHdrs "application/json") "sdfsdf"
        liftIO $ do
          simpleStatus p `shouldBe` badRequest400
          isErrorFormat (simpleBody p) `shouldBe` True
      it "treats simple plpgsql raise as invalid input" $ do
        p <- post "/rpc/problem" "{}"
        liftIO $ do
          simpleStatus p `shouldBe` badRequest400
          isErrorFormat (simpleBody p) `shouldBe` True

    context "unsupported verbs" $ do
      it "DELETE fails" $
        request methodDelete "/rpc/sayhello" [] ""
          `shouldRespondWith` 405
      it "PATCH fails" $
        request methodPatch "/rpc/sayhello" [] ""
          `shouldRespondWith` 405
      it "OPTIONS fails" $
        -- TODO: should return info about the function
        request methodOptions "/rpc/sayhello" [] ""
          `shouldRespondWith` 405
      it "GET fails with 405 on unknown procs" $
        -- TODO: should this be 404?
        get "/rpc/fake" `shouldRespondWith` 405
      it "GET with 405 on known procs" $
        get "/rpc/sayhello" `shouldRespondWith` 405

    it "executes the proc exactly once per request" $ do
      post "/rpc/callcounter" [json| {} |] `shouldRespondWith`
        [json|1|]
        { matchHeaders = [matchContentTypeJson] }
      post "/rpc/callcounter" [json| {} |] `shouldRespondWith`
        [json|2|]
        { matchHeaders = [matchContentTypeJson] }

    context "expects a single json object" $ do
      it "does not expand posted json into parameters" $
        request methodPost "/rpc/singlejsonparam"
          [("Prefer","params=single-object")] [json| { "p1": 1, "p2": "text", "p3" : {"obj":"text"} } |] `shouldRespondWith`
          [json| { "p1": 1, "p2": "text", "p3" : {"obj":"text"} } |]
          { matchHeaders = [matchContentTypeJson] }

      it "accepts parameters from an html form" $
        request methodPost "/rpc/singlejsonparam"
          [("Prefer","params=single-object"),("Content-Type", "application/x-www-form-urlencoded")]
          ("integer=7&double=2.71828&varchar=forms+are+fun&" <>
           "boolean=false&date=1900-01-01&money=$3.99&enum=foo") `shouldRespondWith`
          [json| { "integer": "7", "double": "2.71828", "varchar" : "forms are fun"
                 , "boolean":"false", "date":"1900-01-01", "money":"$3.99", "enum":"foo" } |]
                 { matchHeaders = [matchContentTypeJson] }

    context "a proc that receives no parameters" $
      it "interprets empty string as empty json object on a post request" $
        post "/rpc/noparamsproc" BL.empty `shouldRespondWith`
          [json| "Return value of no parameters procedure." |]
          { matchHeaders = [matchContentTypeJson] }

  describe "weird requests" $ do
    it "can query as normal" $ do
      get "/Escap3e;" `shouldRespondWith`
        [json| [{"so6meIdColumn":1},{"so6meIdColumn":2},{"so6meIdColumn":3},{"so6meIdColumn":4},{"so6meIdColumn":5}] |]
        { matchHeaders = [matchContentTypeJson] }
      get "/ghostBusters" `shouldRespondWith`
        [json| [{"escapeId":1},{"escapeId":3},{"escapeId":5}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "fails if an operator is not given" $
      get "/ghostBusters?id=0" `shouldRespondWith` [json| {"details":"unexpected \"0\" expecting \"not\" or operator (eq, gt, ...)","message":"\"failed to parse filter (0)\" (line 1, column 1)"} |]
        { matchStatus  = 400
        , matchHeaders = [matchContentTypeJson]
        }

    it "will embed a collection" $
      get "/Escap3e;?select=ghostBusters{*}" `shouldRespondWith`
        [json| [{"ghostBusters":[{"escapeId":1}]},{"ghostBusters":[]},{"ghostBusters":[{"escapeId":3}]},{"ghostBusters":[]},{"ghostBusters":[{"escapeId":5}]}] |]
        { matchHeaders = [matchContentTypeJson] }

    it "will embed using a column" $
      get "/ghostBusters?select=escapeId{*}" `shouldRespondWith`
        [json| [{"escapeId":{"so6meIdColumn":1}},{"escapeId":{"so6meIdColumn":3}},{"escapeId":{"so6meIdColumn":5}}] |]
        { matchHeaders = [matchContentTypeJson] }

  describe "binary output" $ do
    it "can query if a single column is selected" $
      request methodGet "/images_base64?select=img&name=eq.A.png" (acceptHdrs "application/octet-stream") ""
        `shouldRespondWith` "iVBORw0KGgoAAAANSUhEUgAAAB4AAAAeAQMAAAAB/jzhAAAABlBMVEUAAAD/AAAb/40iAAAAP0lEQVQI12NgwAbYG2AE/wEYwQMiZB4ACQkQYZEAIgqAhAGIKLCAEQ8kgMT/P1CCEUwc4IMSzA3sUIIdCHECAGSQEkeOTUyCAAAAAElFTkSuQmCC"
        { matchStatus = 200
        , matchHeaders = ["Content-Type" <:> "application/octet-stream; charset=utf-8"]
        }

    it "fails if a single column is not selected" $ do
      request methodGet "/images?select=img,name&name=eq.A.png" (acceptHdrs "application/octet-stream") ""
        `shouldRespondWith` 406
      request methodGet "/images?select=*&name=eq.A.png" (acceptHdrs "application/octet-stream") ""
        `shouldRespondWith` 406
      request methodGet "/images?name=eq.A.png" (acceptHdrs "application/octet-stream") ""
        `shouldRespondWith` 406

    it "concatenates results if more than one row is returned" $
      request methodGet "/images_base64?select=img&name=in.A.png,B.png" (acceptHdrs "application/octet-stream") ""
        `shouldRespondWith` "iVBORw0KGgoAAAANSUhEUgAAAB4AAAAeAQMAAAAB/jzhAAAABlBMVEUAAAD/AAAb/40iAAAAP0lEQVQI12NgwAbYG2AE/wEYwQMiZB4ACQkQYZEAIgqAhAGIKLCAEQ8kgMT/P1CCEUwc4IMSzA3sUIIdCHECAGSQEkeOTUyCAAAAAElFTkSuQmCCiVBORw0KGgoAAAANSUhEUgAAAB4AAAAeAQMAAAAB/jzhAAAABlBMVEX///8AAP94wDzzAAAAL0lEQVQIW2NgwAb+HwARH0DEDyDxwAZEyGAhLODqHmBRzAcn5GAS///A1IF14AAA5/Adbiiz/0gAAAAASUVORK5CYII="
        { matchStatus = 200
        , matchHeaders = ["Content-Type" <:> "application/octet-stream; charset=utf-8"]
        }
  describe "HTTP request env vars" $ do
    it "custom header is set" $
      request methodPost "/rpc/get_guc_value"
                [("Custom-Header", "test")]
          [json| { "name": "request.header.custom-header" } |]
          `shouldRespondWith`
          [str|"test"|]
          { matchStatus  = 200
          , matchHeaders = [ matchContentTypeJson ]
          }
    it "standard header is set" $
      request methodPost "/rpc/get_guc_value"
                [("Origin", "http://example.com")]
          [json| { "name": "request.header.origin" } |]
          `shouldRespondWith`
          [str|"http://example.com"|]
          { matchStatus  = 200
          , matchHeaders = [ matchContentTypeJson ]
          }
    it "current role is available as GUC claim" $
      request methodPost "/rpc/get_guc_value" []
          [json| { "name": "request.jwt.claim.role" } |]
          `shouldRespondWith`
          [str|"postgrest_test_anonymous"|]
          { matchStatus  = 200
          , matchHeaders = [ matchContentTypeJson ]
          }
    it "single cookie ends up as claims" $
      request methodPost "/rpc/get_guc_value" [("Cookie","acookie=cookievalue")]
        [json| {"name":"request.cookie.acookie"} |]
          `shouldRespondWith`
          [str|"cookievalue"|]
          { matchStatus = 200
          , matchHeaders = []
          }

    it "multiple cookies ends up as claims" $
      request methodPost "/rpc/get_guc_value" [("Cookie","acookie=cookievalue;secondcookie=anothervalue")]
        [json| {"name":"request.cookie.secondcookie"} |]
          `shouldRespondWith`
          [str|"anothervalue"|]
          { matchStatus = 200
          , matchHeaders = []
          }
