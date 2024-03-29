var username = "anon";
var manager;

function xxassign()
{

  var name = get_name();

  term = $("#assign").val();

  var jqxhr = $.post("https://api.openstreetmap.social/table/project/ " + name,
                     { gp_id: term, project: name })
  .done(function() {
    refresh_list();
  })
  .fail(function(xhr, status, error) {
    alert("error "+ xhr.status + " " + error);
  })
  .always(function() {
  });
}

function xxdelete()
{
  var name = get_name();
  var gp_id = $("#delinput").val();

  $.ajax({
    url: 'https://api.openstreetmap.social/table/project',
    method: 'DELETE',
    data: { gp_id: gp_id, project: name },
    success: function(result) {
      alert("done");
      refresh_list();
    },
    error: function(xhr,status,error) {
      alert("error "+ xhr.status + " " + error);
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

function refresh_list()
{

  name = get_name();
  $( "#resultget" ).empty();

//  $.get( "https://api.openstreetmap.social/table/project/"+name, function( data ) {
//    $( "#resultget" ).append(data);
//  });

  $.getJSON("https://api.openstreetmap.social/table/project/"+name,
    {
      output: "json",
    },
    function(result) {
      var options = $("#options");

      manager = result.manager;
      $("#manager").html(manager);
      $.each(result.imgs, function(index, value) {
        data = index + ": <a href='https://api.openstreetmap.social/" + value[1] + "'>"+value[0]+"</a>";
        $("#resultget").append(data);
        $("#resultget").append(" [remove]");
        $("#resultget").append("\n<br>");
      });
    }
  );

}

