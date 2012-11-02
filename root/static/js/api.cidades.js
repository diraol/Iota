var zoom_padrao = 5;
var map;
var cidade_data;
var indicadores_data;
var graficos = [];

function loadMap(){
	
	var mapDefaultLocation = new google.maps.LatLng(-14.2350040, -51.9252800);
	var geocoder = new google.maps.Geocoder();

	var mapOptions = {
			center: mapDefaultLocation,
			zoom: zoom_padrao,
			mapTypeId: google.maps.MapTypeId.ROADMAP
		};

	map = new google.maps.Map(document.getElementById("mapa"),mapOptions);
}
	
var cidade_data;
var indicadores_data;
var graficos = [];

function setMap(lat,lng){
	var center = new google.maps.LatLng(lat, lng)
	map.setCenter(center);
}

function loadCidadeData(){
	$.ajax({
		type: 'GET',
		dataType: 'json',
		url: '/api/public/user/$$id'.render({
						id: userID
				}),
		success: function(data, textStatus, jqXHR){
			cidade_data = data;
			showCidadeData();
			loadIndicadoresData();
		},
		error: function(data){
			console.log("erro ao carregar informações da cidade");
		}
	});
}

function showCidadeData(){
	cidade_data.cidade.imagem = "saopaulo.jpg";
	$("#cidades-dados .profile .title").html(cidade_data.cidade.name + ", " + cidade_data.cidade.uf);
	$("#cidades-dados .profile .variaveis .tabela").empty();
	$("#cidades-dados .profile .variaveis .tabela").append("<tr class='item'><td class='label'>Cidade:</td><td class='valor'>$$dado</td></tr>".render({dado: cidade_data.cidade.name}));
	$("#cidades-dados .profile .variaveis .tabela").append("<tr class='item'><td class='label'>Estado:</td><td class='valor'>$$dado</td></tr>".render({dado: cidade_data.cidade.uf}));
	$("#cidades-dados .profile .variaveis .tabela").append("<tr class='item'><td class='label'>País:</td><td class='valor'>$$dado</td></tr>".render({dado: cidade_data.cidade.pais}));

	$.each(cidade_data.variaveis,function(index,value){
		$("#cidades-dados .profile .variaveis .tabela").append("<tr class='item'><td class='label'>$$label:</td><td class='valor'>$$value</td></tr>".render(
			{
				label: cidade_data.variaveis[index].name,
				value: $.formatNumber(cidade_data.variaveis[index].last_value, {format:"#,###", locale:"br"})
			}
		));
	});

	$("#cidades-dados .image").css("background-image","none");
	$("#cidades-dados .image").css("background-image","url('/static/images/"+cidade_data.cidade.imagem+"')");
	
	var diff = $("#cidades-dados .profile .content-fill").height() - $("#cidades-dados .profile").height() + 10;
	if (diff > 10){
		$("#cidades-dados .profile").css("height","+="+diff);
		$("#cidades-dados .resume").css("height","+="+diff);
		$("#cidades-dados .map").css("height","+="+diff);
		$("#cidades-dados #mapa").css("height","+="+diff);
	}

	setMap(cidade_data.cidade.latitude,cidade_data.cidade.longitude);
	
}

function loadIndicadoresData(){
	$.ajax({
		type: 'GET',
		dataType: 'json',
		url: '/api/public/user/$$id/indicator'.render({
						id: userID
				}),
		success: function(data, textStatus, jqXHR){
			indicadores_data = data;
			showIndicadoresData();
		},
		error: function(data){
			console.log("erro ao carregar indicadores da cidade");
		}
	});
}

function showIndicadoresData(){
	var table_content = ""
	$("#cidades-indicadores .table .content-fill").empty();
	table_content += "<table>";
	table_content += "<thead>";
	
	$.each(indicadores_data.resumos, function(period_index, period){
		table_content += "<tr><th></th>";
	
		var datas = period.datas;
		$.each(datas, function(index, value){
			table_content += "<th>$$data</th>".render({data: datas[index].nome});
		});

		table_content += "<th></th></tr></thead>";
		table_content += "<tbody>";
		
		var indicadores = indicadores_data.resumos.yearly.indicadores;
		$.each(indicadores, function(i,item){
			table_content += "<tr><td class='nome'><a href='$$url'>$$nome</a></td>".render({nome: item.name, url:  (window.location.href.substring(-1) == "/") ? item.name_url : window.location.href + "/" + item.name_url});
			for (j = 0; j < item.valores.length; j++){
				if (item.valores[j] == "-") item.valores[j] = 0;
				table_content += "<td class='valor'>$$valor</td>".render({valor: $.formatNumber(item.valores[j], {format:"#,##0.##", locale:"br"})});
			}
			table_content += "<td class='grafico'><canvas id='graph-$$id' width='40' height='20'></canvas></td>".render({id: i});
			graficos[i] = item.valores;
		});
		table_content += "</tbody>";
	});

	table_content += "</table>";
	
	$("#cidades-indicadores .table .content-fill").append(table_content);
	
	geraGraficos();
}


function carregaTabela(){
	$.getJSON("json/indicador.cidade.1.json",
	{
		format: "json"
	},
	function(data) {
		var table_content = ""
		$("#cidades-indicadores .table .content-fill").empty();
		table_content += "<table>";
		table_content += "<thead><tr><th></th><th>2009</th><th>2010</th><th>2011</th><th>2012</th><th></th></tr></thead>";
		table_content += "<tbody>";
		
		$.each(data.dados, function(i,item){
			table_content += "<tr><td class='nome'>$$nome</td>".render({nome: item.nome});
			for (j = 0; j < item.valores.length; j++){
				table_content += "<td class='valor'>$$valor</td>".render({valor: item.valores[j]});
			}
			table_content += "<td class='grafico'><canvas id='graph-$$id' width='40' height='20'></canvas></td>".render({id: i});
			graficos[i] = item.valores;
		});

		table_content += "</tbody></table>";
		
		$("#cidades-indicadores .table .content-fill").append(table_content);
		
		geraGraficos();

	});
}

function geraGraficos(){
	for (i = 0; i < graficos.length; i++){
		var line = new RGraph.Line('graph-'+i, graficos[i]);
		line.Set('chart.ylabels', false);
		line.Set('chart.noaxes', true);
		line.Set('chart.background.grid', false);
		line.Set('chart.hmargin', 0);
		line.Set('chart.gutter.left', 0);
		line.Set('chart.gutter.right', 0);
		line.Set('chart.gutter.top', 0);
		line.Set('chart.gutter.bottom', 0);
		line.Set('chart.colors', ['#b4b4b4']);
		line.Draw();
	}
}
$(document).ready(function(){
	loadMap();
});