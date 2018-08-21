var username = "anon";
var manager;

function xxassign()
{

  var name = get_name();

  term = $("#assign").val();

  var jqxhr = $.post("https://api.openstreetmap.cz/table/project/ " + name,
                     { gp_id: term, project: name })
  .done(function() {
    alert( "done" );
  })
  .fail(function() {
    alert( "error" );
  })
  .always(function() {
    alert( "finished" );
  });
}

function xxdelete()
{
  var name = get_name();
  var gp_id = $("#delinput").val();
  alert(gp_id);

  $.ajax({
    url: 'https://api.openstreetmap.cz/table/project',
    method: 'DELETE',
    data: { gp_id: gp_id, project: name },
    success: function(result) {
      alert("done");
    },
    error: function(request,msg,error) {
      alert("error");
    }
  });
}

function get_name()
{
  return $("#options").val();
}

function get_manager(project)
{
  alert(project);
}

function set_username()
{
//  get_username();
//alert ('username is '+username);
  $("#username").html(username);
}

function get_username()
{

  var jqxhr = $.get("https://api.openstreetmap.cz/table/username/")
  .done(function(data) {
    username = data;
    set_username();
  })
  .fail(function() {
    alert("username error");
  })
  .always(function() {
  });
}

function refresh_list()
{

  name = get_name();
  $( "#resultget" ).empty();

//  $.get( "https://api.openstreetmap.cz/table/project/"+name, function( data ) {
//    $( "#resultget" ).append(data);
//  });

  $.getJSON("https://api.openstreetmap.cz/table/project/"+name,
    {
      output: "json",
    },
    function(result) {
      var options = $("#options");

      manager = result.manager;
      $("#manager").html(manager);
      $.each(result.imgs, function(index, value) {
        data = index + ": <a href='https://api.openstreetmap.cz/" + value[1] + "'>"+value[0]+"</a>";
        $("#resultget").append(data);
        $("#resultget").append(" [remove]");
        $("#resultget").append("\n<br>");
      });
    }
  );

}

